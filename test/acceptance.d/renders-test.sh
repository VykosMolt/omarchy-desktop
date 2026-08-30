#!/bin/bash

set -euo pipefail

source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)/base-test.sh"

# A surface can be present, correctly sized, on the right layer, and paint
# nothing at all. layer_present and layer_on_screen both pass for it, because
# both ask the compositor about geometry and geometry is not paint.
#
# The wallpaper was in exactly that state: Background.qml built its state path
# by hand as $HOME/.local/state/omarchy/... instead of asking Paths, so in the
# isolated session it read a directory that does not exist, the Image had no
# source, and a transparent panel showed the compositor's background colour
# through it. Every existing check passed. It was only caught by looking at
# pixels, and only after someone said "there is no wallpaper".
#
# So: look at pixels.

original_ws=$(hyprctl -j activeworkspace | jq -r .id)
restore() { hyprctl dispatch "hl.dsp.focus({ workspace = \"$original_ws\" })" >/dev/null 2>&1 || true; }
trap restore EXIT

# An empty workspace, so the desktop is what is on screen rather than a window.
empty_ws=""
for candidate in 7 8 9 6 4; do
  if [[ $(hyprctl -j clients | jq --argjson w "$candidate" '[.[] | select(.workspace.id == $w)] | length') == 0 ]]; then
    empty_ws=$candidate
    break
  fi
done
[[ -n $empty_ws ]] || fail "an empty workspace is available to inspect the desktop on"

hyprctl dispatch "hl.dsp.focus({ workspace = \"$empty_ws\" })" >/dev/null
wait_until "the empty workspace is focused" 10 test "$(hyprctl -j activeworkspace | jq -r .id)" = "$empty_ws"
sleep 1

layer_present "omarchy-background" || fail "the background layer exists"
layer_on_screen "omarchy-background" || fail "the background layer is on screen"
pass "the background layer is present and on screen"

# Sample a spread of points. A wallpaper is a photograph: different places are
# different colours. A dead surface is one flat colour everywhere -- whatever
# misc:background_color happens to be.
colours=()
flat=0
for pt in "40,120" "800,300" "1400,600" "200,850" "1200,900"; do
  read -r colour sd <<<"$(patch_stats "$pt 12x12")" || fail "the screen can be captured at $pt"
  colours+=("$colour")
  awk -v s="${sd:-0}" 'BEGIN { exit (s + 0 > 0.5) ? 1 : 0 }' && flat=$((flat + 1))
done

distinct=$(printf '%s\n' "${colours[@]}" | sort -u | wc -l)

if (( distinct == 1 && flat == ${#colours[@]} )); then
  screenshot "failure-background-not-painting"
  fail "the background paints something" \
    "every sample was ${colours[0]} with no variation, which is a transparent surface showing the compositor's fill"
fi
pass "the background paints an image, not a flat fill"

# The same trap catches a lock screen that renders nothing. Its background is
# read from the same state path, and was broken in the same way.
grep -q 'Paths.omarchyState' "$ROOT/shell/plugins/lock/Service.qml" ||
  fail "the lock screen reads its background through the path contract"
grep -q 'Paths.omarchyState' "$ROOT/shell/plugins/background/Background.qml" ||
  fail "the background reads its path through the path contract"
! grep -rn '"/omarchy/current' "$ROOT/shell" --include='*.qml' --include='*.js' >/dev/null ||
  fail "no shell surface builds an omarchy state path by hand"
pass "surfaces resolve state through Paths, not by hand"
