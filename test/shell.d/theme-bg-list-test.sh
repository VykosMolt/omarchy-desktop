#!/bin/bash

# The settings panel picks a background from a list and then sets it by path,
# so the list and the current-background read have to agree on what a path is.
# The list also has to be the same scan omarchy-menu-images does, or the panel
# and the picker would offer different wallpapers.

set -euo pipefail

source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)/base-test.sh"

tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT

export HOME="$tmp/home"
export OMARCHY_PATH="$ROOT"
export PATH="$ROOT/bin:$PATH"

pictures="$HOME/Pictures"
mkdir -p "$pictures/Nested" "$HOME/.config/omarchy"

touch "$pictures/01-a-quiet-lake.jpg" "$pictures/a cat.png" "$pictures/notes.txt"
touch "$pictures/Nested/deeper.webp"

omarchy-theme-bg-dir add "$pictures" >/dev/null

listed=$(omarchy-theme-bg-list)

grep -qF "$pictures/01-a-quiet-lake.jpg"$'\t''A Quiet Lake' <<<"$listed" ||
  fail "a background is listed by path and by the name the picker shows" "$listed"
grep -qF "$pictures/a cat.png"$'\t''A Cat' <<<"$listed" ||
  fail "a path with a space in it is one field, not two" "$listed"
grep -qF "$pictures/Nested/deeper.webp" <<<"$listed" ||
  fail "a registered folder contributes its subdirectories, the way the picker scans them"
grep -qF "notes.txt" <<<"$listed" &&
  fail "a file that is not an image is not a background" "$listed"
pass "the list names every image the picker would offer, by path and by name"

(( $(wc -l <<<"$listed") == 3 )) || fail "nothing is listed twice" "$listed"
pass "nothing is listed twice"

omarchy-theme-bg-current --path >/dev/null 2>&1 &&
  fail "with no background set there is no path to answer with"
[[ $(omarchy-theme-bg-current) == "Unknown" ]] ||
  fail "with no background set the readable form still answers"
pass "no background set is an empty answer rather than a wrong one"

omarchy-theme-bg-set "$pictures/01-a-quiet-lake.jpg" >/dev/null 2>&1 || true

[[ $(omarchy-theme-bg-current --path) == "$pictures/01-a-quiet-lake.jpg" ]] ||
  fail "the current background answers with the path the list offered"
[[ $(omarchy-theme-bg-current) == "A Quiet Lake" ]] ||
  fail "the current background still answers with its readable name"
grep -qF "$(omarchy-theme-bg-current --path)"$'\t' <<<"$listed" ||
  fail "the background in force is one of the ones the list offers"
pass "the background in force matches an entry in the list, by path"
