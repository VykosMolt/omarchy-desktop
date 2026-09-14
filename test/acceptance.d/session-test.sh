#!/bin/bash

set -euo pipefail

source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)/base-test.sh"

# The compositor reports at least one monitor
monitors=$(hyprctl -j monitors | jq 'length')
(( monitors >= 1 )) || fail "compositor reports a monitor"
pass "compositor reports a monitor"

# The Omarchy shell is running and responsive
wait_until "omarchy-shell responds to ping" 60 omarchy-shell shell ping

# Core shell plugins are loaded
plugins=$(omarchy-shell shell listPlugins)
for plugin in \
  omarchy.audio omarchy.background omarchy.bar omarchy.bluetooth \
  omarchy.clipboard omarchy.emojis omarchy.menu \
  omarchy.monitor omarchy.network omarchy.notifications omarchy.power \
  omarchy.settings omarchy.system-monitor omarchy.weather; do
  [[ $plugins == *"$plugin"* ]] || fail "shell plugin is loaded: $plugin" "loaded plugins: $plugins"
  pass "shell plugin is loaded: $plugin"
done

# The bar and background are actually on screen
wait_until "bar layer is on screen" 30 layer_on_screen "omarchy-bar"
wait_until "background layer is on screen" 30 layer_on_screen "omarchy-background"

# Hiding parks the bar off-screen without unmapping its layer surface, and
# revealing brings that same surface back on-screen.
restore_bar_visibility() {
  omarchy-toggle-bar off >/dev/null 2>&1 || true
}
trap restore_bar_visibility EXIT

omarchy-toggle-bar on
wait_until "hidden bar layer stays mapped" 15 layer_present "omarchy-bar"
wait_until "hidden bar layer parks off screen" 15 layer_off_screen "omarchy-bar"
screenshot "success-bar-hidden"

omarchy-toggle-bar off
wait_until "revealed bar layer returns on screen" 15 layer_on_screen "omarchy-bar"
screenshot "success-bar-revealed"
trap - EXIT

# Audio stack is up
wait_until "pipewire is running" 30 wpctl status

# This desktop owns its session units, not the rest of the host's services.
failed_user=$(systemctl --user --failed --no-legend --plain 'omarchy-arch-*' | awk '{print $1}')
[[ -z $failed_user ]] || fail "no failed Omarchy session units" "$failed_user"
pass "no failed Omarchy session units"

screenshot "success-desktop"
