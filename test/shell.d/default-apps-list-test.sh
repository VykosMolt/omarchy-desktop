#!/bin/bash

# The settings panel offers a default browser and editor from a list, then sets
# one from it. Both commands answer from one table, so anything the list offers
# is something the setter accepts -- and anything not installed is offered by
# neither.

set -euo pipefail

source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)/base-test.sh"

tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT

export HOME="$tmp/home"
export OMARCHY_PATH="$ROOT"
export PATH="$tmp/stub-bin:$ROOT/bin:$PATH"

mkdir -p "$HOME/.config" "$tmp/stub-bin"

# The stub directory is what decides what is installed for this test: one
# browser, one editor, and the setter xdg-settings goes through.
for command in firefox helix xdg-settings; do
  printf '#!/bin/bash\nexit 0\n' >"$tmp/stub-bin/$command"
  chmod +x "$tmp/stub-bin/$command"
done

browsers=$(omarchy-default-browser --list)
editors=$(omarchy-default-editor --list)

grep -qxF $'firefox\tFirefox' <<<"$browsers" ||
  fail "an installed browser is offered, by id and by name" "$browsers"
grep -qxF $'helix\tHelix' <<<"$editors" ||
  fail "an installed editor is offered, by id and by name" "$editors"
pass "an installed candidate is offered by id and by name"

grep -qF 'microsoft-edge-stable' <<<"$(command -v microsoft-edge-stable || true)" &&
  fail "the fixture assumes Edge is not installed on this machine"
grep -q '^edge\b' <<<"$browsers" &&
  fail "a browser that is not installed is not offered" "$browsers"
grep -q '^sublime_text\b' <<<"$editors" &&
  fail "an editor that is not installed is not offered" "$editors"
pass "a candidate this machine does not have is not offered"

# Everything the list offers, the setter has to take, and nothing it refuses
# may appear in the list.
while IFS=$'\t' read -r id _name; do
  omarchy-default-browser "$id" >/dev/null 2>&1 ||
    fail "a browser the list offers can be set" "$id"
done <<<"$browsers"
while IFS=$'\t' read -r id _name; do
  omarchy-default-editor "$id" >/dev/null 2>&1 ||
    fail "an editor the list offers can be set" "$id"
done <<<"$editors"
pass "everything offered can be set"

omarchy-default-browser chromium >/dev/null 2>&1 &&
  fail "a browser that is not installed is refused rather than set"
omarchy-default-editor nope >/dev/null 2>&1 &&
  fail "an id from no table at all is refused"
pass "what the list leaves out, the setter refuses"

omarchy-default-editor helix >/dev/null 2>&1
[[ $(omarchy-default-editor) == "helix" ]] || fail "the editor that was set is the one reported back"
pass "the editor that was set is the one reported back"

# zeditor is what the package calls itself and zed is what a person types; the
# stored answer is the same either way.
printf '#!/bin/bash\nexit 0\n' >"$tmp/stub-bin/zeditor"
chmod +x "$tmp/stub-bin/zeditor"
omarchy-default-editor zeditor >/dev/null 2>&1
[[ $(omarchy-default-editor) == "zeditor" ]] || fail "the package name reaches the same editor as the short one"
pass "the package name and the short name name the same editor"
