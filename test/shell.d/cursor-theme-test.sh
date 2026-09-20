#!/bin/bash

# The cursor theme is the user's own, and a colour theme never touches it. When
# the user does pick one the choice has to reach every toolkit at once, so what
# matters here is which directories count as a cursor theme, that every config
# a toolkit reads is written, and that nothing else in those files moves.

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

# Something the user put in gtk-3.0/settings.ini themselves, which a cursor
# change has no business touching.
mkdir -p "$config_home/gtk-3.0"
printf '[Settings]\ngtk-theme-name=Breeze\ngtk-cursor-theme-name=Old\n' >"$config_home/gtk-3.0/settings.ini"

omarchy-cursor-theme set Fixture-Cursors >/dev/null

[[ $(cat "$GSETTINGS_STORE.cursor-theme") == "Fixture-Cursors" ]] ||
  fail "set tells gsettings, which is what GTK apps watch"
grep -qxF 'gtk-cursor-theme-name=Fixture-Cursors' "$config_home/gtk-3.0/settings.ini" ||
  fail "set writes the GTK 3 config" "$(cat "$config_home/gtk-3.0/settings.ini")"
grep -qxF 'gtk-cursor-theme-name=Fixture-Cursors' "$config_home/gtk-4.0/settings.ini" ||
  fail "set writes the GTK 4 config"
grep -qxF 'cursorTheme=Fixture-Cursors' "$config_home/kcminputrc" ||
  fail "set writes the KDE config"
grep -qxF 'Inherits=Fixture-Cursors' "$HOME/.icons/default/index.theme" ||
  fail "set writes the Xcursor default that Xwayland reads"
grep -qxF 'gtk-theme-name=Breeze' "$config_home/gtk-3.0/settings.ini" ||
  fail "set preserves every key it was not asked to change"
pass "set reaches every toolkit and leaves the rest of each file alone"

[[ $(omarchy-cursor-theme get) == "Fixture-Cursors" ]] || fail "get reports the cursor theme in effect"
pass "get reports the cursor theme in effect"

# "default" is Xcursor's placeholder, not a theme anybody picked, so it does
# not get to answer for the toolkit configs that do name one.
printf 'default\n' >"$GSETTINGS_STORE.cursor-theme"
[[ $(omarchy-cursor-theme get) == "Fixture-Cursors" ]] ||
  fail "the Xcursor placeholder does not shadow a theme the configs name"
pass "the Xcursor placeholder does not shadow a theme the configs name"

omarchy-cursor-theme size 32 >/dev/null
[[ $(omarchy-cursor-theme size) == "32" ]] || fail "the cursor size round-trips"
grep -qxF 'gtk-cursor-theme-size=32' "$config_home/gtk-3.0/settings.ini" ||
  fail "the cursor size reaches GTK too"
grep -qxF 'cursorTheme=Fixture-Cursors' "$config_home/kcminputrc" ||
  fail "changing the size keeps the theme"
pass "the size is a setting of its own and keeps the theme it was set against"

for bad in 4 200 huge ""; do
  omarchy-cursor-theme size "$bad" >/dev/null 2>&1 &&
    fail "a cursor size outside what a theme ships is refused" "$bad"
done
[[ $(omarchy-cursor-theme size) == "32" ]] || fail "a refused size changes nothing"
pass "a cursor size outside the accepted range is refused"

# Without a session bus there is no gsettings to tell, and the answer still has
# to come from the files that carry the choice into the next login.
env -u DBUS_SESSION_BUS_ADDRESS HOME="$HOME" OMARCHY_PATH="$ROOT" PATH="$PATH" \
  omarchy-cursor-theme set Fixture-Other-Cursors >/dev/null
[[ $(env -u DBUS_SESSION_BUS_ADDRESS HOME="$HOME" OMARCHY_PATH="$ROOT" PATH="$PATH" omarchy-cursor-theme get) == "Fixture-Other-Cursors" ]] ||
  fail "set and get work without a session bus"
pass "set and get work without a session bus"
