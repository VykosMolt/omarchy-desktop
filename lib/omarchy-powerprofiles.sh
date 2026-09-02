# Power profiles come from two places. power-profiles-daemon names three --
# power-saver, balanced, performance -- and every consumer speaks those. The
# firmware's platform_profile can offer more: a Legion's lenovo-wmi-gamezone
# lists low-power, balanced, performance, max-power and custom, and the daemon
# (0.30, ppd-driver-platform-profile.c) has no name for max-power, so nothing
# going through it can reach that mode. This is the shared vocabulary for the
# scripts that bridge the gap: the daemon's names plus the firmware's own for
# anything the daemon cannot say.
#
# OMARCHY_PLATFORM_PROFILE_DIR exists for tests; the machine's is sysfs.

: "${OMARCHY_PLATFORM_PROFILE_DIR:=/sys/firmware/acpi}"
OMARCHY_PLATFORM_PROFILE_FILE="$OMARCHY_PLATFORM_PROFILE_DIR/platform_profile"
OMARCHY_PLATFORM_PROFILE_CHOICES_FILE="$OMARCHY_PLATFORM_PROFILE_DIR/platform_profile_choices"

# The platform values the daemon maps onto its own three, plus custom, which
# it deliberately ignores. Custom is the firmware's tunable mode, meaningless
# without the knobs that go with it, so it stays out of the ladder here too.
omarchy_platform_profile_is_daemon_mapped() {
  case $1 in
    low-power | quiet | cool | balanced | balanced_performance | balanced-performance | performance | custom) return 0 ;;
    *) return 1 ;;
  esac
}

omarchy_platform_profile_current() {
  local current=""

  [[ -r $OMARCHY_PLATFORM_PROFILE_FILE ]] || return 1
  read -r current <"$OMARCHY_PLATFORM_PROFILE_FILE" || return 1
  [[ -n $current ]] || return 1
  printf '%s\n' "$current"
}

omarchy_platform_profile_choices() {
  [[ -r $OMARCHY_PLATFORM_PROFILE_CHOICES_FILE ]] || return 1
  tr ' ' '\n' <"$OMARCHY_PLATFORM_PROFILE_CHOICES_FILE" | sed '/^$/d'
}

# The profiles only the firmware can name, in the firmware's order.
omarchy_firmware_only_profiles() {
  local choice

  while IFS= read -r choice; do
    [[ -n $choice ]] || continue
    omarchy_platform_profile_is_daemon_mapped "$choice" || printf '%s\n' "$choice"
  done < <(omarchy_platform_profile_choices)
}

omarchy_profile_is_firmware_only() {
  local profile=$1 choice

  [[ -n $profile ]] || return 1
  omarchy_platform_profile_is_daemon_mapped "$profile" && return 1
  while IFS= read -r choice; do
    [[ $choice == "$profile" ]] && return 0
  done < <(omarchy_platform_profile_choices)
  return 1
}
