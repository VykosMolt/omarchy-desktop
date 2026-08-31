#!/bin/bash

set -euo pipefail

source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)/base-test.sh"

resolver="$ROOT/shell/services/icon-index.sh"
tmpdir=$(mktemp -d)
trap 'rm -rf "$tmpdir"' EXIT

home="$tmpdir/home"
data="$tmpdir/data"
stub_bin="$tmpdir/bin"
mkdir -p "$home" "$data/icons" "$stub_bin"

printf '#!/bin/bash\nprintf "%%s\\n" "${OMARCHY_TEST_THEME:-Fancy}"\n' >"$stub_bin/omarchy-icon-theme"
chmod +x "$stub_bin/omarchy-icon-theme"

icon() { mkdir -p "$(dirname "$1")"; : >"$1"; }

# A theme that declares its directories, including a @2x variant under the key
# the spec puts them in.
mkdir -p "$data/icons/Fancy"
cat >"$data/icons/Fancy/index.theme" <<'THEME'
[Icon Theme]
Name=Fancy
Directories=16x16/apps,64x64/apps,scalable/devices
ScaledDirectories=32x32@2x/apps
THEME
icon "$data/icons/Fancy/16x16/apps/browser.png"
icon "$data/icons/Fancy/64x64/apps/browser.png"
icon "$data/icons/Fancy/32x32@2x/apps/scaled.png"
icon "$data/icons/Fancy/32x32/apps/scaled.png"
icon "$data/icons/Fancy/scalable/devices/printer.svg"

# hicolor also has the browser icon, in a scalable directory, which outranks
# every fixed size *within* a theme. It must still lose to the configured theme.
mkdir -p "$data/icons/hicolor"
cat >"$data/icons/hicolor/index.theme" <<'THEME'
[Icon Theme]
Name=hicolor
Directories=scalable/apps
THEME
icon "$data/icons/hicolor/scalable/apps/browser.svg"
icon "$data/icons/hicolor/scalable/apps/hicolor-only.svg"

run_resolver() {
  HOME="$home" XDG_DATA_DIRS="$data" PATH="$stub_bin:$PATH" \
    timeout 30 "$resolver" "$@"
}

out=$(run_resolver browser)
[[ $out == "$data/icons/Fancy/64x64/apps/browser.png" ]] ||
  fail "the configured theme outranks hicolor whatever sizes each ships" "$out"
pass "the configured theme outranks hicolor whatever sizes each ships"

out=$(run_resolver hicolor-only)
[[ $out == "$data/icons/hicolor/scalable/apps/hicolor-only.svg" ]] ||
  fail "an icon the configured theme lacks still comes from hicolor" "$out"
pass "an icon the configured theme lacks still comes from hicolor"

# 32x32@2x draws 64px, so it outranks a plain 32x32 rather than tying with it
# and letting directory order decide.
out=$(run_resolver scaled)
[[ $out == "$data/icons/Fancy/32x32@2x/apps/scaled.png" ]] ||
  fail "a @2x directory is ranked by the pixels it actually draws" "$out"
pass "a @2x directory is ranked by the pixels it actually draws"

# Some desktop entries name a device icon rather than an app one.
out=$(run_resolver printer)
[[ $out == "$data/icons/Fancy/scalable/devices/printer.svg" ]] ||
  fail "device icons are searched alongside app icons" "$out"
pass "device icons are searched alongside app icons"

# A theme without index.theme still has to be found: user-local hicolor trees,
# where Steam drops game icons, ship none.
mkdir -p "$home/.local/share/icons/hicolor/256x256/apps"
icon "$home/.local/share/icons/hicolor/256x256/apps/steam_icon_1.png"
out=$(run_resolver steam_icon_1)
[[ $out == "$home/.local/share/icons/hicolor/256x256/apps/steam_icon_1.png" ]] ||
  fail "a theme shipping no index.theme is still searched" "$out"
pass "a theme shipping no index.theme is still searched"

out=$(run_resolver browser printer)
[[ $(wc -l <<<"$out") == 2 ]] || fail "each requested name resolves once" "$out"
pass "each requested name resolves once"

out=$(run_resolver no-such-icon-anywhere; echo "rc=$?")
[[ $out == "rc=0" ]] || fail "an unresolvable name is skipped without failing" "$out"
pass "an unresolvable name is skipped without failing"

out=$(run_resolver; echo "rc=$?")
[[ $out == "rc=0" ]] || fail "no names asked for is not an error" "$out"
pass "asking for nothing resolves nothing"
