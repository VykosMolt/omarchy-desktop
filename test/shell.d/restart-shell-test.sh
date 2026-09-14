#!/bin/bash

set -euo pipefail

source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)/base-test.sh"
unset WAYLAND_DISPLAY

test_tmp=$(mktemp -d)
restart_pid_one=""
restart_pid_two=""

cleanup() {
  [[ -n $restart_pid_one ]] && kill "$restart_pid_one" 2>/dev/null || true
  [[ -n $restart_pid_two ]] && kill "$restart_pid_two" 2>/dev/null || true
  rm -rf "$test_tmp"
}
trap cleanup EXIT

wrapper_root="$test_tmp/wrapper-root"
wrapper_bin="$test_tmp/wrapper-bin"
mkdir -p "$wrapper_root/shell" "$wrapper_bin"
touch "$wrapper_root/shell/shell.qml"

cat >"$wrapper_bin/qs" <<'SH'
#!/bin/bash

[[ -n ${OMARCHY_TEST_QS_ARGS:-} ]] && printf '%s\n' "$*" >"$OMARCHY_TEST_QS_ARGS"

if [[ ${OMARCHY_TEST_QS_HANG:-0} == 1 ]]; then
  sleep 5
elif [[ ${OMARCHY_TEST_QS_STARTING:-0} == 1 ]]; then
  printf 'Not ready to accept queries yet.\n'
else
  printf 'ok\n'
fi
SH
chmod +x "$wrapper_bin/qs"

wrapper_error=$(PATH="$wrapper_bin:$PATH" \
  OMARCHY_PATH="$wrapper_root" \
  OMARCHY_SHELL_IPC_TIMEOUT=0.1s \
  OMARCHY_TEST_QS_HANG=1 \
  "$ROOT/bin/omarchy-shell" shell ping 2>&1) && fail "hung shell IPC returns a failure"
[[ $wrapper_error == "omarchy-shell is not responding" ]] || fail "hung shell IPC reports that the shell is unresponsive" "$wrapper_error"
pass "shell IPC calls time out when Quickshell is unresponsive"

# A starting shell answers on stdout and exits 0, so a ping reads it as up.
wrapper_error=$(PATH="$wrapper_bin:$PATH" \
  OMARCHY_PATH="$wrapper_root" \
  OMARCHY_TEST_QS_STARTING=1 \
  "$ROOT/bin/omarchy-shell" shell ping 2>&1) && fail "a starting shell answers IPC calls with a failure"
[[ $wrapper_error == "omarchy-shell is not ready" ]] || fail "a starting shell reports that it is not ready" "$wrapper_error"
pass "shell IPC calls fail while Quickshell is still starting"

PATH="$wrapper_bin:$PATH" \
OMARCHY_PATH="$wrapper_root" \
OMARCHY_TEST_QS_STARTING=1 \
  "$ROOT/bin/omarchy-shell" -q shell ping >/dev/null 2>&1 ||
  fail "quiet best-effort IPC calls tolerate a starting shell"
pass "quiet best-effort IPC calls tolerate a starting shell"

wrapper_args="$test_tmp/wrapper-args"
PATH="$wrapper_bin:$PATH" \
OMARCHY_PATH="$wrapper_root" \
OMARCHY_TEST_QS_ARGS="$wrapper_args" \
  "$ROOT/bin/omarchy-shell" shell ping >/dev/null

grep -F -- 'ipc -n -p' "$wrapper_args" >/dev/null || fail "shell IPC targets the newest live Quickshell instance"
pass "shell IPC targets the newest live Quickshell instance"

restart_root="$test_tmp/restart-root"
restart_bin="$restart_root/bin"
restart_state="$test_tmp/restart-pids"
restart_log="$test_tmp/restart.log"
restart_env_log="$test_tmp/restart-env.log"
dispatch_log="$test_tmp/dispatch.log"
ipc_log="$test_tmp/ipc.log"
runtime_dir="$test_tmp/runtime"
mkdir -p "$restart_root/shell" "$restart_root/lib" "$restart_bin" "$runtime_dir"
ln -s "$ROOT/lib/omarchy-paths.sh" "$restart_root/lib/omarchy-paths.sh"
touch "$restart_root/shell/shell.qml"
ln -s "$ROOT/bin/omarchy-shell" "$restart_bin/omarchy-shell"
ln -s "$ROOT/bin/omarchy-launch-shell" "$restart_bin/omarchy-launch-shell"
ln -s "$ROOT/bin/omarchy-cmd-missing" "$restart_bin/omarchy-cmd-missing"
ln -s "$ROOT/bin/omarchy-hyprland-session-locked" "$restart_bin/omarchy-hyprland-session-locked"

cat >"$restart_bin/qs" <<'SH'
#!/bin/bash

printf '%s\n' "$*" >>"$OMARCHY_TEST_IPC_LOG"

case "$*" in
  *'shell ping')
    [[ $* == *"-p $OMARCHY_TEST_SESSION_PATH/shell"* ]] &&
      grep -Fx '303' "$OMARCHY_TEST_QS_STATE" >/dev/null &&
      printf 'ok\n'
    ;;
  *'lock lock')
    touch "$OMARCHY_TEST_QS_STATE.locked"
    printf 'ok\n'
    ;;
  *'lock status')
    if [[ ${OMARCHY_TEST_LOCK_STATUS_INVALID:-0} == 1 ]]; then
      printf 'not-json\n'
      exit 0
    fi
    if [[ -f $OMARCHY_TEST_QS_STATE.locked ]]; then
      printf '{"secure": true, "requested": true}\n'
    else
      printf '{"secure": false, "requested": false}\n'
    fi
    ;;
esac
SH

cat >"$restart_bin/quickshell" <<'SH'
#!/bin/bash

case " $* " in
  *' list '*)
    [[ ${OMARCHY_TEST_LIST_FAILS:-0} == 0 ]] || exit 1
    state_file=$OMARCHY_TEST_QS_STATE
    if [[ -s $state_file.stale-count ]] && (( $(<"$state_file.stale-count") > 0 )); then
      count=$(<"$state_file.stale-count")
      printf '%s\n' "$((count - 1))" >"$state_file.stale-count"
      state_file=$state_file.stale
    fi
    if [[ ! -s $state_file && ${OMARCHY_TEST_UNRELATED_INSTANCE:-0} == 0 ]]; then
      printf 'No running instances.\n'
    else
      jq -Rn --arg config "$OMARCHY_TEST_SESSION_PATH/shell/shell.qml" \
        --arg unrelated "${OMARCHY_TEST_UNRELATED_INSTANCE:-0}" \
        '[inputs | select(length > 0) | { id: ("fixture-" + .), config_path: $config }]
         + (if $unrelated == "1" then [{id:"other-desktop",config_path:"/other/desktop/shell.qml"}] else [] end)' "$state_file"
    fi
    exit
    ;;
esac
printf '%s\n' "$*" >>"$OMARCHY_TEST_QS_LOG"

case " $* " in
  *' kill --id '*)
    [[ ${OMARCHY_TEST_QS_KILL_FAILS:-0} == 1 ]] && exit 1
    pid=${3#fixture-}
    [[ $pid =~ ^[0-9]+$ ]] || exit 1
    [[ ${OMARCHY_TEST_KILL_FAIL_PID:-} != "$pid" ]] || exit 1
    if (( ${OMARCHY_TEST_STALE_LISTS:-0} > 0 )); then
      cp "$OMARCHY_TEST_QS_STATE" "$OMARCHY_TEST_QS_STATE.stale"
      printf '%s\n' "$OMARCHY_TEST_STALE_LISTS" >"$OMARCHY_TEST_QS_STATE.stale-count"
    fi
    # 303 is a fixture-only replacement, never a real process to signal.
    if [[ $pid != 303 ]]; then
      kill "$pid" 2>/dev/null
      while kill -0 "$pid" 2>/dev/null; do sleep 0.01; done
    fi
    awk -v pid="$pid" '$0 != pid' "$OMARCHY_TEST_QS_STATE" >"$OMARCHY_TEST_QS_STATE.next"
    mv "$OMARCHY_TEST_QS_STATE.next" "$OMARCHY_TEST_QS_STATE"
    ;;
  *' -n -p '*)
    printf '%s\n' "${OMARCHY_TEST_TRANSIENT_ENV-unset}" >"$OMARCHY_TEST_QS_ENV_LOG"
    printf '303\n' >"$OMARCHY_TEST_QS_STATE"
    ;;
esac
SH

cat >"$restart_bin/hyprctl" <<'SH'
#!/bin/bash

if [[ ${1:-} == "-j" && ${2:-} == "instances" ]]; then
  printf '%s\n' "${OMARCHY_TEST_INSTANCES:-[]}"
elif [[ ${1:-} == "-j" && ${2:-} == "monitors" ]]; then
  [[ -z ${OMARCHY_TEST_REQUIRED_SIGNATURE:-} || ${HYPRLAND_INSTANCE_SIGNATURE:-} == "$OMARCHY_TEST_REQUIRED_SIGNATURE" ]] || exit 2
  [[ ${OMARCHY_TEST_MONITORS_UNKNOWN:-0} == 0 ]] || exit 2
  # Hyprland reports an active session lock as a reason the monitor cannot hand
  # a client the whole screen, not as a workspace.
  if [[ ${OMARCHY_TEST_SESSION_LOCKED:-0} == 1 ]]; then
    printf '[{"name":"eDP-1","solitaryBlockedBy":["WINDOWED","LOCK","CANDIDATE"]}]\n'
  else
    printf '[{"name":"eDP-1","solitaryBlockedBy":["WINDOWED","CANDIDATE"]}]\n'
  fi
elif [[ ${1:-} == "dispatch" && ${2:-} == hl.dsp.exec_cmd* ]]; then
  printf '%s\n' "${2:-}" >>"$OMARCHY_TEST_DISPATCH_LOG"
  OMARCHY_PATH="$OMARCHY_TEST_SESSION_PATH" \
    env -u OMARCHY_TEST_TRANSIENT_ENV omarchy-launch-shell
  printf 'ok\n'
elif [[ ${1:-} == "dispatch" ]]; then
  exit 1
fi
SH

# Keep the test hermetic where journald has no usable stream socket.
cat >"$restart_bin/systemd-cat" <<'SH'
#!/bin/bash

while (( $# > 0 )); do
  [[ $1 == "--" ]] && { shift; break; }
  shift
done
exec "$@"
SH

cat >"$restart_bin/systemctl" <<'SH'
#!/bin/bash

if [[ ${1:-} == "--user" && ${2:-} == "show-environment" ]]; then
  printf 'OMARCHY_PATH=%s\n' "$OMARCHY_TEST_SESSION_PATH"
elif [[ ${1:-} == "--user" && ${2:-} == "try-restart" ]]; then
  exit 0
elif [[ ${1:-} == "--user" && ${2:-} == "restart" && ${3:-} == "omarchy-arch-shell.service" ]]; then
  printf '%s\n' managed-restart >> "$OMARCHY_TEST_DISPATCH_LOG"
  [[ ${OMARCHY_TEST_SERVICE_FAILS:-0} == 0 ]] || exit 1
  OMARCHY_PATH="$OMARCHY_TEST_SESSION_PATH" env -u OMARCHY_TEST_TRANSIENT_ENV omarchy-launch-shell
else
  exit 1
fi
SH

chmod +x "$restart_bin/qs" "$restart_bin/quickshell" "$restart_bin/hyprctl" "$restart_bin/systemd-cat" "$restart_bin/systemctl"

sleep 30 &
restart_pid_one=$!
sleep 30 &
restart_pid_two=$!
printf '%s\n%s\n' "$restart_pid_one" "$restart_pid_two" >"$restart_state"

caller_root="$test_tmp/caller-root"
mkdir -p "$caller_root/shell"
touch "$caller_root/shell/shell.qml"

PATH="$restart_bin:$PATH" \
OMARCHY_PATH="$caller_root" \
XDG_RUNTIME_DIR="$runtime_dir" \
OMARCHY_TEST_QS_STATE="$restart_state" \
OMARCHY_TEST_QS_LOG="$restart_log" \
OMARCHY_TEST_QS_ENV_LOG="$restart_env_log" \
OMARCHY_TEST_DISPATCH_LOG="$dispatch_log" \
OMARCHY_TEST_IPC_LOG="$ipc_log" \
OMARCHY_TEST_SESSION_PATH="$restart_root" \
OMARCHY_TEST_TRANSIENT_ENV=leaked \
  timeout 5 "$ROOT/bin/omarchy-restart-shell"

if kill -0 "$restart_pid_one" 2>/dev/null; then
  fail "restart stops the first matching shell instance"
fi
if kill -0 "$restart_pid_two" 2>/dev/null; then
  fail "restart stops duplicate matching shell instances"
fi
wait "$restart_pid_one" 2>/dev/null || true
wait "$restart_pid_two" 2>/dev/null || true
restart_pid_one=""
restart_pid_two=""
[[ $(<"$restart_state") == 303 ]] || fail "restart leaves exactly one fresh shell instance"
[[ $(grep -c '^-n -p ' "$restart_log") == 1 ]] || fail "restart launches one fresh shell process"
grep -F 'kill --id fixture-' "$restart_log" >/dev/null || fail "restart stops the shell from the session checkout"
[[ $(<"$restart_env_log") == "unset" ]] || fail "restart uses the Hyprland session environment for the fresh shell"
grep -F 'hl.dsp.exec_cmd("omarchy-launch-shell")' "$dispatch_log" >/dev/null || fail "restart launches the fresh shell through Hyprland"
grep -F "ipc -n -p $restart_root/shell --any-display call -- shell ping" "$ipc_log" >/dev/null || fail "restart checks readiness in the session checkout"
pass "restart replaces duplicate shell instances from the session checkout"

# A kill that matches nothing used to fall through to the readiness poll, where
# the shell it failed to stop answered the ping and the restart reported success
# having restarted nothing. The caller then believes it is running new code.
printf '303\n' >"$restart_state"
: >"$restart_log"
unstoppable_rc=0
unstoppable_output=$(
  PATH="$restart_bin:$PATH" \
  OMARCHY_PATH="$caller_root" \
  XDG_RUNTIME_DIR="$runtime_dir" \
  OMARCHY_TEST_QS_STATE="$restart_state" \
  OMARCHY_TEST_QS_LOG="$restart_log" \
  OMARCHY_TEST_QS_ENV_LOG="$restart_env_log" \
  OMARCHY_TEST_DISPATCH_LOG="$dispatch_log" \
  OMARCHY_TEST_IPC_LOG="$ipc_log" \
  OMARCHY_TEST_SESSION_PATH="$restart_root" \
  OMARCHY_TEST_QS_KILL_FAILS=1 \
    timeout 5 "$ROOT/bin/omarchy-restart-shell" 2>&1
) || unstoppable_rc=$?

(( unstoppable_rc != 0 )) ||
  fail "restart fails when the running shell cannot be stopped" "$unstoppable_output"
grep -F 'Could not stop the running Omarchy shell' <<<"$unstoppable_output" >/dev/null ||
  fail "restart says why it did not restart" "$unstoppable_output"
! grep -q '^-n -p ' "$restart_log" ||
  fail "restart launches no second shell when the first is still running" "$(<"$restart_log")"
pass "restart refuses to report success when the running shell cannot be stopped"

: >"$restart_log"
printf '303\n' >"$restart_state"
touch "$restart_state.locked"

locked_error=$(PATH="$restart_bin:$PATH" \
  OMARCHY_PATH="$restart_root" \
  XDG_RUNTIME_DIR="$runtime_dir" \
  OMARCHY_TEST_SESSION_LOCKED=1 \
  OMARCHY_TEST_QS_STATE="$restart_state" \
  OMARCHY_TEST_QS_LOG="$restart_log" \
  OMARCHY_TEST_DISPATCH_LOG="$dispatch_log" \
  OMARCHY_TEST_IPC_LOG="$ipc_log" \
  OMARCHY_TEST_SESSION_PATH="$restart_root" \
  "$ROOT/bin/omarchy-restart-shell" 2>&1) && fail "restart refuses while the shell lock is active"

[[ $locked_error == "Refusing to restart Omarchy shell while the session is locked." ]] || fail "locked restart explains why it was refused" "$locked_error"
[[ $(<"$restart_state") == 303 ]] || fail "locked restart preserves the running shell"
[[ ! -s $restart_log ]] || fail "locked restart does not stop or launch Quickshell"
pass "restart preserves the shell while its lock is active"

# A LOCK session without an active locker — dead shell or a crash-handler
# relaunch holding no lock — is the failsafe: restart must proceed,
# re-acquire the session lock, and wait for it to report secure.
sleep 30 &
restart_pid_one=$!
printf '%s\n' "$restart_pid_one" >"$restart_state"
rm -f "$restart_state.locked"
: >"$restart_log"
: >"$ipc_log"

PATH="$restart_bin:$PATH" \
OMARCHY_PATH="$restart_root" \
XDG_RUNTIME_DIR="$runtime_dir" \
OMARCHY_TEST_SESSION_LOCKED=1 \
OMARCHY_TEST_QS_STATE="$restart_state" \
OMARCHY_TEST_QS_LOG="$restart_log" \
OMARCHY_TEST_QS_ENV_LOG="$restart_env_log" \
OMARCHY_TEST_DISPATCH_LOG="$dispatch_log" \
OMARCHY_TEST_IPC_LOG="$ipc_log" \
OMARCHY_TEST_SESSION_PATH="$restart_root" \
  timeout 5 "$ROOT/bin/omarchy-restart-shell" || fail "locked restart recovers when the lock client is dead"

if kill -0 "$restart_pid_one" 2>/dev/null; then
  fail "dead-lock recovery stops the stale shell instance"
fi
wait "$restart_pid_one" 2>/dev/null || true
restart_pid_one=""
[[ $(<"$restart_state") == 303 ]] || fail "dead-lock recovery leaves one fresh shell instance"
grep -F "ipc -n -p $restart_root/shell --any-display call -- lock lock" "$ipc_log" >/dev/null || fail "dead-lock recovery re-acquires the session lock"
grep -F "ipc -n -p $restart_root/shell --any-display call -- lock status" "$ipc_log" >/dev/null || fail "dead-lock recovery waits for the lock to become secure"
pass "restart recovers a locked session whose lock client died"

# Session restarts use the owning unit even if its old process exited after
# IPC shutdown. A direct Hyprland spawn would leave systemd showing it dead.
: > "$restart_state"
rm -f "$restart_state.locked"
: > "$dispatch_log"
: > "$restart_log"
touch "$runtime_dir/omarchy-arch-session.env"
exec 8> "$runtime_dir/omarchy-arch-session.lock"
flock -n 8
PATH="$restart_bin:$PATH" \
OMARCHY_PATH="$restart_root" OMARCHY_ARCH_SESSION=1 HYPRLAND_INSTANCE_SIGNATURE=fixture-known \
XDG_RUNTIME_DIR="$runtime_dir" \
OMARCHY_TEST_QS_STATE="$restart_state" \
OMARCHY_TEST_QS_LOG="$restart_log" \
OMARCHY_TEST_QS_ENV_LOG="$restart_env_log" \
OMARCHY_TEST_DISPATCH_LOG="$dispatch_log" \
OMARCHY_TEST_IPC_LOG="$ipc_log" \
OMARCHY_TEST_SESSION_PATH="$restart_root" \
  timeout 5 "$ROOT/bin/omarchy-restart-shell" || fail "managed restart succeeds"
[[ $(cat "$dispatch_log") == managed-restart ]] || fail "managed restart bypasses its session unit"
[[ $(cat "$restart_state") == 303 ]] || fail "managed restart did not produce a ready shell"
exec 8>&-
pass "an isolated restart keeps the shell owned by its session service"

: > "$restart_log"
unknown_rc=0
PATH="$restart_bin:$PATH" OMARCHY_PATH="$restart_root" XDG_RUNTIME_DIR="$runtime_dir" \
OMARCHY_TEST_SESSION_PATH="$restart_root" OMARCHY_TEST_MONITORS_UNKNOWN=1 \
OMARCHY_TEST_QS_LOG="$restart_log" \
  "$ROOT/bin/omarchy-restart-shell" > "$test_tmp/unknown-output" 2>&1 || unknown_rc=$?
(( unknown_rc != 0 )) || fail "unknown compositor lock state cannot authorize restart"
[[ ! -s $restart_log ]] || fail "unknown compositor state still killed the shell"
pass "restart refuses when compositor lock state is unknown"

run_restart_case() {
  PATH="$restart_bin:$PATH" OMARCHY_PATH="$restart_root" XDG_RUNTIME_DIR="$runtime_dir" \
    OMARCHY_TEST_QS_STATE="$restart_state" OMARCHY_TEST_QS_LOG="$restart_log" \
    OMARCHY_TEST_QS_ENV_LOG="$restart_env_log" OMARCHY_TEST_DISPATCH_LOG="$dispatch_log" \
    OMARCHY_TEST_IPC_LOG="$ipc_log" OMARCHY_TEST_SESSION_PATH="$restart_root" \
    "$ROOT/bin/omarchy-restart-shell" "$@"
}

printf '303\n' >"$restart_state"
: >"$restart_log"
if OMARCHY_TEST_SESSION_LOCKED=1 OMARCHY_TEST_LOCK_STATUS_INVALID=1 run_restart_case >"$test_tmp/invalid-lock" 2>&1; then
  fail "malformed lock IPC cannot authorize restarting a compositor-locked shell"
fi
[[ ! -s $restart_log ]] || fail "malformed lock status still killed a possible live locker"
pass "unknown shell lock state preserves every running instance"

: >"$restart_log"
if OMARCHY_TEST_LIST_FAILS=1 run_restart_case >/dev/null 2>&1; then
  fail "failed instance discovery cannot authorize restart"
fi
[[ ! -s $restart_log ]] || fail "failed discovery still mutated shell processes"
pass "restart requires successful instance discovery"

# A successful first kill must not hide failure to stop a second duplicate.
sleep 30 &
restart_pid_one=$!
printf '%s\n303\n' "$restart_pid_one" >"$restart_state"
: >"$dispatch_log"
if OMARCHY_TEST_KILL_FAIL_PID=303 run_restart_case >"$test_tmp/partial-kill" 2>&1; then
  fail "a surviving duplicate prevents replacement"
fi
wait "$restart_pid_one" 2>/dev/null || true
restart_pid_one=""
[[ $(<"$restart_state") == 303 && ! -s $dispatch_log ]] || fail "partial shutdown launched over a surviving instance"
pass "partial shutdown failure never launches a duplicate replacement"

# A compositor locked behind its failsafe with no shell at all needs no kill.
: >"$restart_state"
rm -f "$restart_state.locked"
: >"$restart_log"
OMARCHY_TEST_SESSION_LOCKED=1 run_restart_case || fail "a missing lock client can be recovered"
[[ $(<"$restart_state") == 303 && -e $restart_state.locked ]] || fail "missing-locker recovery did not secure the session"
! rg -q '^kill ' "$restart_log" || fail "missing-locker recovery unexpectedly killed a process"
pass "verified absence of a locker permits failsafe recovery"

: >"$restart_state"
: >"$dispatch_log"
exec 8>"$runtime_dir/omarchy-arch-session.lock"
flock -n 8
if OMARCHY_ARCH_SESSION=1 HYPRLAND_INSTANCE_SIGNATURE=fixture-known OMARCHY_TEST_SERVICE_FAILS=1 run_restart_case >"$test_tmp/service-failure" 2>&1; then
  fail "failed managed startup cannot report restart success"
fi
exec 8>&-
[[ $(<"$dispatch_log") == managed-restart && ! -s $restart_state ]] || fail "managed startup failure was bypassed"
pass "managed service startup failures propagate without a detached replacement"

# SSH has no compositor signature. Match the isolated --config path, not the
# newest compositor belonging to the account's other desktop session.
python3 -c 'import time; time.sleep(30)' --config "$test_tmp/isolated/hypr/hyprland.lua" &
restart_pid_one=$!
instances=$(jq -nc --argjson pid "$restart_pid_one" '[{pid:$pid,instance:"isolated-match"},{pid:2147483647,instance:"unrelated-newest"}]')
: >"$restart_state"
rm -f "$restart_state.locked"
exec 8>"$runtime_dir/omarchy-arch-session.lock"
flock -n 8
OMARCHY_ARCH_SESSION=1 OMARCHY_SESSION_CONFIG_HOME="$test_tmp/isolated" \
  OMARCHY_TEST_INSTANCES="$instances" OMARCHY_TEST_REQUIRED_SIGNATURE=isolated-match \
  run_restart_case || fail "managed restart locates its exact compositor config"
: >"$restart_log"
if OMARCHY_ARCH_SESSION=1 OMARCHY_SESSION_CONFIG_HOME="$test_tmp/other-config" \
  OMARCHY_TEST_INSTANCES="$instances" run_restart_case >/dev/null 2>&1; then
  fail "managed restart must not use an unmatched compositor"
fi
[[ ! -s $restart_log ]] || fail "unmatched compositor discovery still touched the shell"
exec 8>&-
kill "$restart_pid_one"
wait "$restart_pid_one" 2>/dev/null || true
restart_pid_one=""
pass "managed restart locates its own compositor and refuses unmatched instances"

# The real CLI prints a human-readable empty result even with --json, and
# kill's successful IPC response can precede process/registry disappearance.
printf '303\n' >"$restart_state"
: >"$restart_log"
: >"$dispatch_log"
OMARCHY_TEST_STALE_LISTS=2 run_restart_case || fail "restart waits for acknowledged kills to finish disappearing"
[[ $(<"$restart_state") == 303 && -s $dispatch_log ]] || fail "restart did not launch after the old instance disappeared"
[[ $(<"$restart_state.stale-count") == 0 ]] || fail "restart skipped shutdown confirmation"
pass "restart handles delayed shutdown and the real CLI's textual empty result"

: >"$restart_state"
: >"$restart_log"
OMARCHY_TEST_UNRELATED_INSTANCE=1 run_restart_case || fail "another desktop's shell does not block this restart"
! rg -q '^kill ' "$restart_log" || fail "restart killed another desktop's shell"
pass "global discovery filters exact configuration paths before any process action"
