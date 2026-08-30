#!/bin/bash

set -euo pipefail

source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)/base-test.sh"

units_dir="$ROOT/default/systemd/user"

# Every session unit is gated on the session lock, so nothing here can start
# inside the other Hyprland session on this account.
for unit in "$units_dir"/omarchy-arch-*.service; do
  grep -Fx "ExecCondition=/usr/bin/bash -c '! /usr/bin/flock -n %t/omarchy-arch-session.lock /usr/bin/true'" "$unit" >/dev/null ||
    fail "$(basename "$unit") starts without holding the session lock, so it can run in another session"
  grep -Fx 'EnvironmentFile=%t/omarchy-arch-session.env' "$unit" >/dev/null ||
    fail "$(basename "$unit") does not read the session environment file"
  grep -Fx 'PartOf=omarchy-arch-session.target' "$unit" >/dev/null ||
    fail "$(basename "$unit") is not part of the session target, so it outlives the session"
done
pass "every session service is locked to this session and dies with it"

target="$units_dir/omarchy-arch-session.target"
for unit in "$units_dir"/omarchy-arch-*.service; do
  grep -Fx "Wants=$(basename "$unit")" "$target" >/dev/null ||
    fail "$(basename "$unit") is never pulled in by the session target"
done
pass "the session target pulls in every session service"

bt_agent="$units_dir/omarchy-arch-bt-agent.service"
grep -Fx 'ExecCondition=/usr/bin/systemctl is-active --quiet bluetooth.service' "$bt_agent" >/dev/null ||
  fail "bt-agent skips when bluetooth.service is inactive"
grep -Fx 'Restart=on-failure' "$bt_agent" >/dev/null ||
  fail "bt-agent still restarts after runtime failures"
pass "bt-agent skips when bluetooth is inactive and restarts on failure"

sleep_service="$units_dir/omarchy-arch-sleep-lock.service"
grep -Fx 'After=dbus.socket wayland-session-waitenv.service' "$sleep_service" >/dev/null ||
  fail "sleep lock starts before the session environment is known"
grep -Fx 'ExecStart=/usr/bin/env omarchy-system-sleep-monitor' "$sleep_service" >/dev/null ||
  fail "sleep lock does not run the sleep monitor"
pass "sleep lock waits for the session environment before monitoring suspend"

fcitx_service="$units_dir/omarchy-arch-fcitx5.service"
grep -Fx 'ConditionFileIsExecutable=/usr/bin/fcitx5' "$fcitx_service" >/dev/null ||
  fail "fcitx5 unit runs on machines without fcitx5 installed"
! grep -F 'fcitx5' "$ROOT/default/hypr/autostart.lua" >/dev/null ||
  fail "fcitx5 is autostarted from Hyprland; an unsupervised launch dies silently"

# fcitx5 exits 0 when another instance already owns the input method, which is
# what happens when the host session started one. Restart=always turned that
# into a hot loop: one session logged over thirty thousand restarts.
grep -Fx 'Restart=on-failure' "$fcitx_service" >/dev/null ||
  fail "a clean fcitx5 exit is restarted, which loops when another instance owns the input method"
grep -Fx 'StartLimitBurst=5' "$fcitx_service" >/dev/null ||
  fail "nothing bounds an fcitx5 crash loop"
pass "fcitx5 restarts on a crash but not when another instance owns the input method"

# A start limit only works where systemd reads it.
for unit in "$units_dir"/omarchy-arch-*.service; do
  awk '/^\[Service\]/ { in_service = 1 } in_service && /^StartLimit/ { exit 1 }' "$unit" ||
    fail "$(basename "$unit") puts a start limit in [Service], where systemd ignores it"
done
pass "start limits are declared where systemd reads them"

# Hyprland lives in session.slice under uwsm's wayland-wm@ service. Marking any
# ancestor of that as an oomd kill candidate puts the compositor back in the
# victim pool, which is the crash this whole thing exists to prevent.
oomd_slice="$units_dir/app.slice.d/10-oomd.conf"
grep -Fx 'ManagedOOMMemoryPressure=kill' "$oomd_slice" >/dev/null ||
  fail "nothing is a kill candidate, so systemd-oomd watches the machine thrash and never acts"
grep -Fx 'ManagedOOMSwap=kill' "$oomd_slice" >/dev/null ||
  fail "no swap backstop for the slower shape of the same failure"
candidates=$(grep -rlE '^ManagedOOM(MemoryPressure|Swap)=kill' "$ROOT/default/systemd" 2>/dev/null || true)
[[ $candidates == "$oomd_slice" ]] ||
  fail "systemd-oomd kill candidacy is set outside app.slice, which can select the compositor: $candidates"
pass "only user app scopes are systemd-oomd kill candidates"

# The desktop must not depend on a line inside the compositor's config to
# appear. A login once produced a bare compositor because Hyprland read another
# session's config, so autostart.lua never ran and nothing started.
launcher="$ROOT/bin/omarchy-arch-session"
grep -F 'wayland-wm@Hyprland.service.d/20-omarchy-arch-session.conf' "$launcher" >/dev/null ||
  fail "the session target is not pulled in by the compositor unit"
grep -F 'Wants=omarchy-arch-session.target' "$launcher" >/dev/null ||
  fail "the compositor drop-in does not want the session target"
! grep -F 'Requires=omarchy-arch-session.target' "$launcher" >/dev/null ||
  fail "a failing session target would take the compositor down with it"
grep -F 'systemctl --user start omarchy-arch-session.target' "$ROOT/default/hypr/autostart.lua" >/dev/null ||
  fail "Hyprland no longer starts the session target itself"
pass "the session target starts from the compositor unit as well as from Hyprland"

# This port installs nothing into /etc and enables nothing permanently: the
# session links its own units at runtime and drops them with the session.
! grep -rn 'systemctl --user enable' "$ROOT/bin/omarchy-arch-session" >/dev/null ||
  fail "the session enables a unit permanently instead of linking it for the session"
grep -F 'systemctl --user link --runtime --force' "$ROOT/bin/omarchy-arch-session" >/dev/null ||
  fail "the session does not link its units at runtime"
pass "the session links its units for this session only"
