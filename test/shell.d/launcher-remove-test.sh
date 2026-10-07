#!/bin/bash

set -euo pipefail

source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)/base-test.sh"

tmp_dir="$(mktemp -d)"
trap 'rm -rf "$tmp_dir"' EXIT

mkdir -p "$tmp_dir/data/applications" "$tmp_dir/system/applications" "$tmp_dir/bin"

cat >"$tmp_dir/bin/omarchy-notification-send" <<'SCRIPT'
#!/bin/bash
printf 'notify::%s\n' "$*" >>"$TEST_LOG"
SCRIPT
chmod +x "$tmp_dir/bin/omarchy-notification-send"

cat >"$tmp_dir/bin/update-desktop-database" <<'SCRIPT'
#!/bin/bash
:
SCRIPT
chmod +x "$tmp_dir/bin/update-desktop-database"

# Removing software is not this desktop's job, so nothing here may reach for a
# package manager. A stub that logs makes an attempt visible instead of silent.
for tool in pacman flatpak; do
  cat >"$tmp_dir/bin/$tool" <<SCRIPT
#!/bin/bash
printf '$tool::%s\\n' "\$*" >>"\$TEST_LOG"
SCRIPT
  chmod +x "$tmp_dir/bin/$tool"
done

cat >"$tmp_dir/data/applications/aliens.desktop" <<'DESKTOP'
[Desktop Entry]
Name=Aliens
Exec=retroarch -L /usr/lib/libretro/fbneo_libretro.so /home/example/Games/roms/fbneo/aliens.zip
DESKTOP

cat >"$tmp_dir/system/applications/native.desktop" <<'DESKTOP'
[Desktop Entry]
Name=Native
Exec=native
DESKTOP

export TEST_LOG="$tmp_dir/log"
: >"$TEST_LOG"
export PATH="$tmp_dir/bin:$PATH"
export XDG_DATA_HOME="$tmp_dir/data"
export XDG_DATA_DIRS="$tmp_dir/system"

export OMARCHY_CONFIG_HOME="$tmp_dir/omarchy-config"
cp "$tmp_dir/data/applications/aliens.desktop" "$tmp_dir/aliens.before"
cp "$tmp_dir/system/applications/native.desktop" "$tmp_dir/native.before"
"$ROOT/bin/omarchy-remove-launcher-entry" aliens.desktop Aliens
"$ROOT/bin/omarchy-remove-launcher-entry" native.desktop Native
"$ROOT/bin/omarchy-remove-launcher-entry" aliens.desktop Aliens
cmp "$tmp_dir/aliens.before" "$tmp_dir/data/applications/aliens.desktop" || fail "user desktop entry remains unchanged"
cmp "$tmp_dir/native.before" "$tmp_dir/system/applications/native.desktop" || fail "system desktop entry remains unchanged"
[[ $(cat "$OMARCHY_CONFIG_HOME/launcher.hides") == $'aliens\nnative' ]] || fail "private hide list stores each normalized ID once"
[[ ! -s $TEST_LOG ]] || fail "hiding invokes no package manager or global desktop update"
pass "hiding an app preserves all desktop files and changes only the Omarchy list"

for bad in ../escape $'bad\nentry' ''; do
  if "$ROOT/bin/omarchy-remove-launcher-entry" "$bad" >/dev/null 2>&1; then
    fail "invalid launcher ID is refused"
  fi
done
rm "$OMARCHY_CONFIG_HOME/launcher.hides"
ln -s "$tmp_dir/data/applications/aliens.desktop" "$OMARCHY_CONFIG_HOME/launcher.hides"
if "$ROOT/bin/omarchy-remove-launcher-entry" another.desktop >/dev/null 2>&1; then
  fail "launcher hide refuses an external destination symlink"
fi
cmp "$tmp_dir/aliens.before" "$tmp_dir/data/applications/aliens.desktop" || fail "escaping symlink leaves host desktop entry unchanged"
pass "launcher IDs and preference symlinks cannot escape the private list"
