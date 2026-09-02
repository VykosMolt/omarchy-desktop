#!/bin/bash

set -euo pipefail

source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)/base-test.sh"

tmp_dir=$(mktemp -d)
trap 'rm -rf "$tmp_dir"' EXIT

mkdir -p "$tmp_dir/bin" "$tmp_dir/state"

# The daemon stub behaves like the real one where it matters here: `set` of
# the profile it already holds writes nothing, and any other `set` lands the
# matching platform value in the fake sysfs, the way ppd's platform_profile
# driver does.
cat >"$tmp_dir/bin/powerprofilesctl" <<'EOF'
#!/bin/bash

active=$(<"$POWERPROFILES_ACTIVE")
if [[ $1 == "list" ]]; then
  # ppd prints performance first; omarchy-powerprofiles-list reverses that.
  for p in performance balanced power-saver; do
    if [[ $p == "$active" ]]; then printf '* %s:\n' "$p"; else printf '  %s:\n' "$p"; fi
  done
elif [[ $1 == "get" ]]; then
  printf '%s\n' "$active"
elif [[ $1 == "set" ]]; then
  [[ ${POWERPROFILES_SET_FAIL:-0} == "0" ]] || exit 1
  printf '%s\n' "$2" >>"$POWERPROFILES_LOG"
  [[ $2 == "$active" ]] && exit 0
  printf '%s\n' "$2" >"$POWERPROFILES_ACTIVE"
  case $2 in
    power-saver) platform=low-power ;;
    *) platform=$2 ;;
  esac
  printf '%s\n' "$platform" >"$OMARCHY_PLATFORM_PROFILE_DIR/platform_profile"
fi
EOF
chmod +x "$tmp_dir/bin/powerprofilesctl"

cat >"$tmp_dir/bin/busctl" <<'EOF'
#!/bin/bash

case ${@: -1} in
  OnBattery)
    if [[ ${ON_BATTERY:-0} == "1" ]]; then echo "b true"; else echo "b false"; fi
    ;;
  ActiveProfile)
    printf 's "%s"\n' "$(<"$POWERPROFILES_ACTIVE")"
    ;;
  Profiles)
    echo 'aa{sv} 3 2 "Profile" s "power-saver" "Driver" s "multiple" 2 "Profile" s "balanced" "Driver" s "multiple" 2 "Profile" s "performance" "Driver" s "multiple"'
    ;;
esac
EOF
chmod +x "$tmp_dir/bin/busctl"

# Escalation must never happen inside a test; a stub that records the attempt
# and fails is how that is proven.
for tool in sudo pkexec; do
  cat >"$tmp_dir/bin/$tool" <<'EOF'
#!/bin/bash
printf '%s\n' "$*" >>"$ESCALATION_LOG"
exit 1
EOF
  chmod +x "$tmp_dir/bin/$tool"
done

# A Legion's firmware: the daemon can name four of these, and max-power is
# the one it cannot.
mkdir -p "$tmp_dir/sysfs"
printf 'low-power balanced performance max-power custom\n' >"$tmp_dir/sysfs/platform_profile_choices"
printf 'balanced\n' >"$tmp_dir/sysfs/platform_profile"
printf 'balanced\n' >"$tmp_dir/ppd-active"

export PATH="$tmp_dir/bin:$ROOT/bin:$PATH"
export POWERPROFILES_LOG="$tmp_dir/calls"
export POWERPROFILES_ACTIVE="$tmp_dir/ppd-active"
export ESCALATION_LOG="$tmp_dir/escalations"
export OMARCHY_POWERPROFILES_STATE_DIR="$tmp_dir/state"
export OMARCHY_PLATFORM_PROFILE_DIR="$tmp_dir/sysfs"
export OMARCHY_PATH="$ROOT"

"$ROOT/bin/omarchy-powerprofiles-set" ac balanced
[[ $(<"$tmp_dir/state/ac") == "balanced" ]] || fail "power profile stores AC preference"
[[ $(tail -n 1 "$tmp_dir/calls") == "balanced" ]] || fail "power profile applies selected AC preference"
pass "power profile stores and applies AC preference"

"$ROOT/bin/omarchy-powerprofiles-set" ac
[[ $(tail -n 1 "$tmp_dir/calls") == "balanced" ]] || fail "power profile restores AC preference"
pass "power profile restores AC preference"

if POWERPROFILES_SET_FAIL=1 "$ROOT/bin/omarchy-powerprofiles-set" ac performance; then
  fail "power profile reports a failed selection"
fi
[[ $(<"$tmp_dir/state/ac") == "balanced" ]] || fail "power profile preserves preference after failed selection"
pass "power profile persists only successful selections"

"$ROOT/bin/omarchy-powerprofiles-set" battery performance
[[ $(<"$tmp_dir/state/battery") == "performance" ]] || fail "power profile stores battery preference"
pass "power profile stores battery preference separately"

"$ROOT/bin/omarchy-powerprofiles-set" ac
[[ $(tail -n 1 "$tmp_dir/calls") == "balanced" ]] || fail "battery preference does not replace AC preference"
pass "power profile keeps AC and battery preferences separate"

ON_BATTERY=1 "$ROOT/bin/omarchy-powerprofiles-set"
[[ $(tail -n 1 "$tmp_dir/calls") == "performance" ]] || fail "autodetect restores battery preference"
pass "power profile autodetect restores battery preference"

rm "$tmp_dir/state/ac"
ON_BATTERY=0 "$ROOT/bin/omarchy-powerprofiles-set"
[[ $(tail -n 1 "$tmp_dir/calls") == "performance" ]] || fail "power profile uses performance as AC default"
pass "power profile retains performance as AC default"

"$ROOT/bin/omarchy-powerprofiles-set" ac power-saver
"$ROOT/bin/omarchy-powerprofiles-init"
[[ $(tail -n 1 "$tmp_dir/calls") == "power-saver" ]] || fail "init restores the autodetected preference"
pass "power profile init restores the autodetected preference"

rg -F '["omarchy-powerprofiles-set", pendingPowerSource]' "$ROOT/shell/plugins/services/battery/Service.qml" >/dev/null ||
  fail "battery service applies profiles through Omarchy command"
pass "battery service applies profiles through Omarchy command"

rg -F 'omarchy-powerprofiles-set autodetect' "$ROOT/shell/plugins/menu/Menu.qml" >/dev/null ||
  fail "power profile menu persists selections through Omarchy command"
pass "power profile menu persists selections through Omarchy command"

# ---- profiles only the firmware can name ----------------------------------

platform_profile() { cat "$tmp_dir/sysfs/platform_profile"; }
assert_no_escalation() {
  [[ ! -s $ESCALATION_LOG ]] || fail "$1" "$(<"$ESCALATION_LOG")"
  pass "$1"
}

"$ROOT/bin/omarchy-powerprofiles-set" ac balanced

listed=$("$ROOT/bin/omarchy-powerprofiles-list" | tr '\n' ' ')
[[ $listed == "power-saver balanced performance max-power " ]] || fail "list ends with the firmware-only profile" "$listed"
pass "list ends with the firmware-only profile"

listed=$("$ROOT/bin/omarchy-powerprofiles-list" --active-state | tr '\n' ' ')
[[ $listed == *$'balanced\t1'* && $listed == *$'max-power\t0'* ]] || fail "list marks the daemon's profile active on a daemon profile" "$listed"
pass "list marks the daemon's profile active on a daemon profile"

: >"$tmp_dir/calls"
"$ROOT/bin/omarchy-powerprofiles-set" ac max-power
[[ $(platform_profile) == "max-power" ]] || fail "set writes a firmware-only profile to sysfs" "$(platform_profile)"
pass "set writes a firmware-only profile to sysfs"
[[ $(head -n 1 "$tmp_dir/calls") == "performance" ]] || fail "set gives the daemon performance before the firmware profile" "$(<"$tmp_dir/calls")"
pass "set gives the daemon performance before the firmware profile"
[[ $(<"$tmp_dir/state/ac") == "max-power" ]] || fail "set remembers a firmware-only profile"
pass "set remembers a firmware-only profile"
assert_no_escalation "a writable profile file never escalates"

listed=$("$ROOT/bin/omarchy-powerprofiles-list" --active-state | tr '\n' ' ')
[[ $listed == *$'max-power\t1'* && $listed == *$'performance\t0'* ]] || fail "list marks the firmware profile active and the daemon's stale mark not" "$listed"
pass "list marks the firmware profile active and the daemon's stale mark not"

sensors=$("$ROOT/bin/omarchy-hw-sensors")
[[ $sensors == *$'profile\tmax-power'* ]] || fail "sensors report the firmware profile the daemon cannot name" "$sensors"
pass "sensors report the firmware profile the daemon cannot name"
[[ $sensors == *$'profiles\tpower-saver balanced performance max-power'* ]] || fail "sensors report the full ladder" "$sensors"
pass "sensors report the full ladder"

# The daemon believes performance is active, so a plain `set performance`
# would be a no-op and the firmware would stay on max-power.
: >"$tmp_dir/calls"
"$ROOT/bin/omarchy-powerprofiles-set" ac performance
[[ $(platform_profile) == "performance" ]] || fail "set leaves a firmware-only profile for the daemon's" "$(platform_profile)"
pass "set leaves a firmware-only profile for the daemon's"
[[ $(tr '\n' ' ' <"$tmp_dir/calls") == "balanced performance " ]] || fail "set bounces through a neighbour when the daemon thinks it is already there" "$(<"$tmp_dir/calls")"
pass "set bounces through a neighbour when the daemon thinks it is already there"

"$ROOT/bin/omarchy-powerprofiles-set" ac max-power
: >"$tmp_dir/calls"
"$ROOT/bin/omarchy-powerprofiles-set" ac power-saver
[[ $(platform_profile) == "low-power" ]] || fail "set needs no bounce for a real daemon transition" "$(platform_profile)"
[[ $(tr '\n' ' ' <"$tmp_dir/calls") == "power-saver " ]] || fail "set needs no bounce for a real daemon transition" "$(<"$tmp_dir/calls")"
pass "set needs no bounce for a real daemon transition"

sensors=$("$ROOT/bin/omarchy-hw-sensors")
[[ $sensors == *$'profile\tpower-saver'* ]] || fail "sensors report the daemon's name on a daemon profile" "$sensors"
pass "sensors report the daemon's name on a daemon profile"

# A restore may not put up a password dialog. With the file writable it
# restores; without, it settles for performance and escalates nothing. The
# daemon re-applies its own profile on resume and the firmware follows, which
# is what a restore is for.
"$ROOT/bin/omarchy-powerprofiles-set" ac max-power
printf 'performance\n' >"$tmp_dir/sysfs/platform_profile"
"$ROOT/bin/omarchy-powerprofiles-set" ac
[[ $(platform_profile) == "max-power" ]] || fail "restore reaches a firmware-only profile when the file is writable" "$(platform_profile)"
pass "restore reaches a firmware-only profile when the file is writable"

printf 'performance\n' >"$tmp_dir/sysfs/platform_profile"
chmod a-w "$tmp_dir/sysfs/platform_profile"
if [[ -w $tmp_dir/sysfs/platform_profile ]]; then
  pass "running as root; skipping the read-only restore check"
else
  : >"$ESCALATION_LOG"
  "$ROOT/bin/omarchy-powerprofiles-set" ac 2>/dev/null
  [[ $(platform_profile) == "performance" ]] || fail "restore settles for performance when the file is not writable" "$(platform_profile)"
  pass "restore settles for performance when the file is not writable"
  assert_no_escalation "restore never escalates"
  [[ $(<"$tmp_dir/state/ac") == "max-power" ]] || fail "restore keeps the remembered choice"
  pass "restore keeps the remembered choice"

  : >"$ESCALATION_LOG"
  if "$ROOT/bin/omarchy-powerprofiles-firmware" --no-prompt max-power 2>/dev/null; then
    fail "firmware writer refuses to escalate under --no-prompt"
  fi
  assert_no_escalation "firmware writer refuses to escalate under --no-prompt"

  : >"$ESCALATION_LOG"
  if "$ROOT/bin/omarchy-powerprofiles-firmware" max-power </dev/null 2>/dev/null; then
    fail "firmware writer reports a failed escalation"
  fi
  [[ $(<"$ESCALATION_LOG") == *"omarchy-powerprofiles-firmware max-power" ]] || fail "firmware writer re-executes itself through pkexec without a terminal" "$(<"$ESCALATION_LOG")"
  pass "firmware writer re-executes itself through pkexec without a terminal"
fi
chmod u+w "$tmp_dir/sysfs/platform_profile"

if "$ROOT/bin/omarchy-powerprofiles-firmware" turbo-nonsense 2>/dev/null; then
  fail "firmware writer rejects a profile the firmware does not offer"
fi
pass "firmware writer rejects a profile the firmware does not offer"

if "$ROOT/bin/omarchy-powerprofiles-set" ac custom 2>/dev/null; then
  fail "set keeps custom out of the ladder"
fi
pass "set keeps custom out of the ladder"
