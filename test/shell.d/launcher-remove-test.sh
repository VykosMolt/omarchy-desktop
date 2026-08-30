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

"$ROOT/bin/omarchy-remove-launcher-entry" aliens.desktop Aliens

[[ ! -e $tmp_dir/data/applications/aliens.desktop ]] || fail "launcher remove deletes user-owned desktop files"
pass "launcher remove deletes user-owned desktop files"

if "$ROOT/bin/omarchy-remove-launcher-entry" native.desktop Native 2>"$tmp_dir/err"; then
  fail "launcher remove refuses a system launcher entry"
fi
grep -q 'remove the package that owns it instead' "$tmp_dir/err" ||
  fail "launcher remove explains why a system entry was left alone" "$(<"$tmp_dir/err")"
[[ -e $tmp_dir/system/applications/native.desktop ]] || fail "launcher remove leaves system desktop files in place"
pass "launcher remove refuses a system launcher entry"

[[ ! -s $TEST_LOG ]] ||
  fail "launcher remove never reaches for a package manager or notifies" "$(<"$TEST_LOG")"
pass "launcher remove never reaches for a package manager"
