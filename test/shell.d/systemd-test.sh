#!/bin/bash

set -euo pipefail

source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)/base-test.sh"

units_dir="$ROOT/default/systemd/user"
lock_condition="ExecCondition=/usr/bin/bash -c '/usr/bin/flock -n -E 75 \"%t/omarchy-arch-session.lock\" /usr/bin/true; [[ \$\$? == 75 ]]'"

# Every session unit is gated on the session lock, so nothing here can start
# inside the other Hyprland session on this account.
for unit in "$units_dir"/omarchy-arch-*.service; do
  grep -Fx "$lock_condition" "$unit" >/dev/null ||
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


# A start limit only works where systemd reads it.
for unit in "$units_dir"/omarchy-arch-*.service; do
  awk '/^\[Service\]/ { in_service = 1 } in_service && /^StartLimit/ { exit 1 }' "$unit" ||
    fail "$(basename "$unit") puts a start limit in [Service], where systemd ignores it"
done
pass "start limits are declared where systemd reads them"

# The desktop must not depend on a line inside the compositor's config to
# appear. A login once produced a bare compositor because Hyprland read another
# session's config, so autostart.lua never ran and nothing started.
launcher="$ROOT/bin/omarchy-arch-session"
grep -F 'wayland-wm@${wm_instance}.service.d/20-omarchy-arch-session.conf' "$launcher" >/dev/null ||
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

# Only lock contention authorizes a service. File errors must not turn the
# inversion of flock into permission to start in a different session.
tmpdir=$(mktemp -d)
trap 'rm -rf "$tmpdir"' EXIT
condition=${lock_condition#* -c }
condition=${condition:1:${#condition}-2}
condition=${condition//\%t/$tmpdir}
condition=${condition//\$\$/\$}
if bash -c "$condition"; then fail "an unlocked session cannot start services"; fi
exec 8> "$tmpdir/omarchy-arch-session.lock"
flock -n 8
bash -c "$condition" || fail "a held session lock permits services"
exec 8>&-
rm "$tmpdir/omarchy-arch-session.lock"
mkdir "$tmpdir/omarchy-arch-session.lock"
if bash -c "$condition" 2>/dev/null; then fail "a lock I/O error cannot authorize services"; fi
rmdir "$tmpdir/omarchy-arch-session.lock"
pass "session service gate distinguishes contention from lock errors"

# Exercise the real launcher with a fake HOME and stub services. The losing
# concurrent launcher must not run recovery, rewrite env, or relink anything.
mkdir -p "$tmpdir/home/omarchy-arch-port/runtime" "$tmpdir/config/hypr" "$tmpdir/bin"
touch "$tmpdir/config/hypr/hyprland.lua"
cat > "$tmpdir/home/omarchy-arch-port/runtime/env.sh" <<'ENV'
export OMARCHY_PATH="$ROOT"
export OMARCHY_ARCH_SESSION=1
export OMARCHY_SESSION_CONFIG_HOME="$OMARCHY_LAUNCH_TEST/config"
export OMARCHY_SESSION_STATE_HOME="$OMARCHY_LAUNCH_TEST/state"
export OMARCHY_SESSION_CACHE_HOME="$OMARCHY_LAUNCH_TEST/cache"
export OMARCHY_SESSION_DATA_HOME="$OMARCHY_LAUNCH_TEST/data"
export OMARCHY_CONFIG_HOME="$OMARCHY_SESSION_CONFIG_HOME/omarchy"
export OMARCHY_STATE_HOME="$OMARCHY_SESSION_STATE_HOME/omarchy"
export OMARCHY_CACHE_HOME="$OMARCHY_SESSION_CACHE_HOME/omarchy"
export OMARCHY_DATA_HOME="$OMARCHY_SESSION_DATA_HOME/omarchy"
export OMARCHY_SLEEP_LOCK_UNIT=omarchy-arch-sleep-lock.service
ENV
cat > "$tmpdir/bin/systemctl" <<'STUB'
#!/bin/bash
printf '%s\n' "$*" >> "$OMARCHY_LAUNCH_TEST/calls"
if [[ $* == "--user show graphical-session.target --property=ActiveState --value" ]]; then
  [[ ${OMARCHY_LAUNCH_QUERY_ERROR:-0} == 1 ]] && exit 2
  printf '%s\n' "${OMARCHY_LAUNCH_TARGET_STATE:-inactive}"
fi
if [[ $* == "--user stop graphical-session.target" && ${OMARCHY_LAUNCH_STOP_ERROR:-0} == 1 ]]; then exit 2; fi
exit 0
STUB
cat > "$tmpdir/bin/pgrep" <<'STUB'
#!/bin/bash
[[ ${OMARCHY_LAUNCH_PGREP_ERROR:-0} == 1 ]] && exit 2
if [[ ${OMARCHY_LAUNCH_DESKTOP_RACE:-0} == 1 && -e $OMARCHY_LAUNCH_TEST/calls ]]; then exit 0; fi
[[ ${OMARCHY_LAUNCH_ACTIVE_DESKTOP:-0} == 1 ]]
STUB
cat > "$tmpdir/bin/omarchy-hw-recover-internal-monitor" <<'STUB'
#!/bin/bash
printf '%s\n' recovery >> "$OMARCHY_LAUNCH_TEST/calls"
if [[ ${OMARCHY_LAUNCH_WAIT_RECOVERY:-0} == 1 ]]; then
  touch "$OMARCHY_LAUNCH_TEST/recovery-ready"
  while [[ ! -e $OMARCHY_LAUNCH_TEST/recovery-release ]]; do sleep 0.02; done
fi
STUB
cat > "$tmpdir/bin/start-hyprland" <<'STUB'
#!/bin/bash
exit 99
STUB
# Initial preferences are read from deterministic host stubs, never the live
# account's settings bus. The launcher still runs the real initializer.
cat > "$tmpdir/bin/gsettings" <<'STUB'
#!/bin/bash
[[ $1 == get ]] || exit 99
case $3 in
  icon-theme) echo "'Fixture Icons'" ;;
  cursor-theme) echo "'Fixture Cursor'" ;;
  cursor-size) echo 24 ;;
esac
STUB
printf '#!/bin/bash\nprintf "Fixture Mono\\n"\n' > "$tmpdir/bin/fc-match"
printf '#!/bin/bash\nprintf "fixture.desktop\\n"\n' > "$tmpdir/bin/xdg-settings"
cat > "$tmpdir/bin/uwsm" <<'STUB'
#!/bin/bash
if [[ " $* " == *" -n "* ]]; then
  printf '%s\n' dry-run
  exit 0
fi
if [[ ${OMARCHY_LAUNCH_WAIT_UWSM:-0} == 1 ]]; then
  stop_fixture() {
    touch "$OMARCHY_LAUNCH_TEST/stopping"
    while [[ ! -e $OMARCHY_LAUNCH_TEST/teardown-release ]]; do sleep 0.02; done
    exit 23
  }
  trap stop_fixture TERM
  touch "$OMARCHY_LAUNCH_TEST/uwsm-ready"
  while true; do sleep 0.02; done
fi
if flock -n "$XDG_RUNTIME_DIR/omarchy-arch-session.lock" true; then exit 90; fi
[[ -s $XDG_RUNTIME_DIR/omarchy-arch-session.env ]] || exit 91
[[ $(stat -c %a "$XDG_RUNTIME_DIR/omarchy-arch-session.env") == 600 ]] || exit 92
[[ $(umask) == 0022 ]] || exit 93
grep -Fx "KITTY_CONFIG_DIRECTORY=\"$OMARCHY_LAUNCH_TEST/config/kitty\"" "$XDG_RUNTIME_DIR/omarchy-arch-session.env" >/dev/null || exit 94
[[ $DBUS_SESSION_BUS_ADDRESS == "unix:path=$XDG_RUNTIME_DIR/bus" ]] || exit 95
[[ -s $KITTY_CONFIG_DIRECTORY/kitty.conf && -s $OMARCHY_CONFIG_HOME/appearance.ini ]] || exit 97
[[ $(cat "$OMARCHY_STATE_HOME/defaults/browser") == fixture.desktop ]] || exit 98
wm_instance=$(systemd-escape start-hyprland)
[[ -f $XDG_RUNTIME_DIR/systemd/user/wayland-wm@${wm_instance}.service.d/20-omarchy-arch-session.conf ]] || exit 96
printf '%s\n' "$@" > "$OMARCHY_LAUNCH_TEST/argv"
exit 17
STUB
chmod +x "$tmpdir/bin/"*
run_launcher() {
  (umask 022; HOME="$tmpdir/home" XDG_RUNTIME_DIR="$tmpdir" \
    OMARCHY_LAUNCH_TEST="$tmpdir" PATH="$tmpdir/bin:$ROOT/bin:$PATH" "$launcher" "$@")
}

printf '%s\n' untouched > "$tmpdir/omarchy-arch-session.env"
if OMARCHY_LAUNCH_ACTIVE_DESKTOP=1 run_launcher > "$tmpdir/out" 2>&1; then fail "a live desktop must prevent an Omarchy launch"; fi
grep -F 'A graphical desktop is already running' "$tmpdir/out" >/dev/null || fail "live desktop rejection is explained"
[[ $(cat "$tmpdir/omarchy-arch-session.env") == untouched && ! -e $tmpdir/calls ]] || fail "a live desktop rejection touched session state"
pass "a live desktop is left untouched by a rejected Omarchy launch"
if OMARCHY_LAUNCH_PGREP_ERROR=1 run_launcher > "$tmpdir/out" 2>&1; then fail "a failed process check must prevent launch"; fi
[[ $(cat "$tmpdir/omarchy-arch-session.env") == untouched && ! -e $tmpdir/calls ]] || fail "a failed process check touched session state"
pass "a failed process check cannot authorize session startup"

exec 8> "$tmpdir/omarchy-arch-session.lock"
flock -n 8
if run_launcher > "$tmpdir/out" 2>&1; then fail "a second session is rejected"; fi
[[ $(cat "$tmpdir/omarchy-arch-session.env") == untouched && ! -e $tmpdir/calls ]] || fail "a rejected launch mutated session state"
exec 8>&-
pass "a competing launcher cannot mutate the active session"

run_launcher --dry-run >/dev/null || fail "dry-run reaches uwsm"
[[ $(cat "$tmpdir/omarchy-arch-session.env") == untouched && ! -e $tmpdir/calls ]] || fail "dry-run mutated session state"
pass "dry-run leaves session runtime files untouched"
[[ ! -e $tmpdir/config/omarchy && ! -e $tmpdir/config/kitty && ! -e $tmpdir/state ]] || fail "a blocked or dry-run startup initialized preferences"
pass "blocked and dry-run startup never initialize private preferences"

if OMARCHY_LAUNCH_QUERY_ERROR=1 run_launcher > "$tmpdir/out" 2>&1; then fail "a failed target query must prevent startup"; fi
[[ $(cat "$tmpdir/omarchy-arch-session.env") == untouched ]] || fail "query failure changed the environment"
! grep -Eq 'stop|recovery|link' "$tmpdir/calls" || fail "query failure changed session state"
rm "$tmpdir/calls"
if OMARCHY_LAUNCH_DESKTOP_RACE=1 OMARCHY_LAUNCH_TARGET_STATE=active run_launcher > "$tmpdir/out" 2>&1; then fail "a newly running desktop must prevent stale recovery"; fi
[[ $(cat "$tmpdir/omarchy-arch-session.env") == untouched ]] || fail "desktop race changed the environment"
! grep -Eq 'stop|recovery|link' "$tmpdir/calls" || fail "desktop race stopped a live session"
rm "$tmpdir/calls"
pass "stale recovery refuses failed queries and a newly running desktop"

launcher_status=0
run_launcher --verbose || launcher_status=$?
(( launcher_status == 17 )) || fail "launcher preserves uwsm status and holds its lock" "$launcher_status"
[[ ! -e $tmpdir/omarchy-arch-session.env ]] || fail "launcher leaves stale session environment"
wm_instance=$(systemd-escape start-hyprland)
[[ ! -e $tmpdir/systemd/user/wayland-wm@${wm_instance}.service.d/20-omarchy-arch-session.conf ]] || fail "launcher leaves compositor drop-in"
flock -n "$tmpdir/omarchy-arch-session.lock" true || fail "launcher retains lock after exit"
grep -Fx -- "$tmpdir/config/hypr/hyprland.lua" "$tmpdir/argv" >/dev/null || fail "launcher loses isolated compositor config"
grep -Fx -- '--verbose' "$tmpdir/argv" >/dev/null || fail "launcher loses compositor arguments"
pass "session launcher holds ownership through uwsm and cleans up after exit"
! grep -F -- '--user stop graphical-session.target' "$tmpdir/calls" >/dev/null || fail "an inactive target was stopped"

rm "$tmpdir/calls"
launcher_status=0
OMARCHY_LAUNCH_TARGET_STATE=active run_launcher || launcher_status=$?
(( launcher_status == 17 )) || fail "stale recovery did not reach uwsm" "$launcher_status"
[[ $(grep -Fc -- '--user stop graphical-session.target' "$tmpdir/calls") == 1 ]] || fail "stale recovery must stop only the shared stale target once"
! grep -F -- 'uwsm stop' "$tmpdir/calls" >/dev/null || fail "stale recovery used blanket UWSM teardown"
rm "$tmpdir/calls"
launcher_status=0
OMARCHY_LAUNCH_TARGET_STATE=active OMARCHY_LAUNCH_STOP_ERROR=1 run_launcher > "$tmpdir/out" 2>&1 || launcher_status=$?
(( launcher_status == 2 )) || fail "stale target stop failure was ignored" "$launcher_status"
! grep -Eq 'recovery|link' "$tmpdir/calls" || fail "startup continued after failed stale recovery"
pass "only stale targets are recovered and stop failures prevent startup"

# Real signals exercise Bash's interrupted wait. Only processes owned by this
# fixture receive them; the stubs never reach systemd or the compositor.
LAUNCHER="$launcher" FIXTURE="$tmpdir" python3 - <<'PYTHON'
import os, signal, subprocess, time
from pathlib import Path
root = Path(os.environ["FIXTURE"])
env = os.environ.copy()
env.update(HOME=str(root / "home"), XDG_RUNTIME_DIR=str(root),
           OMARCHY_LAUNCH_TEST=str(root), PATH=str(root / "bin") + ":" + env["ROOT"] + "/bin:" + env["PATH"])


def await_file(path, proc):
    deadline = time.monotonic() + 5
    while time.monotonic() < deadline:
        if path.exists():
            return
        if proc.poll() is not None:
            raise AssertionError(f"launcher exited early: {proc.returncode}")
        time.sleep(.02)
    raise AssertionError(f"did not observe {path.name}")


def cleanup(proc):
    (root / "teardown-release").touch()
    (root / "recovery-release").touch()
    if proc.poll() is None:
        proc.terminate()
    try:
        proc.wait(timeout=5)
    except subprocess.TimeoutExpired:
        proc.kill()
        proc.wait()


proc = subprocess.Popen([os.environ["LAUNCHER"]], env={**env, "OMARCHY_LAUNCH_WAIT_UWSM": "1"})
try:
    await_file(root / "uwsm-ready", proc)
    proc.send_signal(signal.SIGTERM)
    await_file(root / "stopping", proc)
    assert proc.poll() is None, "supervisor exited before uwsm teardown"
    assert (root / "omarchy-arch-session.env").exists(), "environment removed during teardown"
    probe = subprocess.run(["flock", "-n", "-E", "75", str(root / "omarchy-arch-session.lock"), "true"])
    assert probe.returncode == 75, "session ownership released during teardown"
    (root / "teardown-release").touch()
    assert proc.wait(timeout=5) == 23, "interrupted wait lost the child's final status"
    assert not (root / "omarchy-arch-session.env").exists(), "environment survived teardown"
finally:
    cleanup(proc)

(root / "argv").unlink(missing_ok=True)
(root / "recovery-release").unlink(missing_ok=True)
proc = subprocess.Popen([os.environ["LAUNCHER"]], env={**env, "OMARCHY_LAUNCH_WAIT_RECOVERY": "1"})
try:
    await_file(root / "recovery-ready", proc)
    proc.send_signal(signal.SIGTERM)
    (root / "recovery-release").touch()
    assert proc.wait(timeout=5) == 143, "pre-launch signal did not abort startup"
    assert not (root / "argv").exists(), "uwsm started after termination was requested"
    assert not (root / "omarchy-arch-session.env").exists(), "aborted launch left its environment"
finally:
    cleanup(proc)
PYTHON
pass "session signals preserve ownership through teardown and abort pre-launch startup"
