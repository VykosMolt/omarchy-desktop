#!/bin/bash

set -euo pipefail

source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)/base-test.sh"

run_node_test <<'JS'
const menu = requireFromRoot('shell/plugins/menu/MenuModel.js')

const items = {
  'setup.default.browser.brave': { id: 'setup.default.browser.brave', when: 'omarchy-pkg-present brave-bin', checked: '[[ "$(omarchy-default-browser)" == "brave" ]]' },
  'setup.default.browser.zen': { id: 'setup.default.browser.zen', when: 'omarchy-pkg-present zen-browser-bin', checked: '[[ "$(omarchy-default-browser)" == "zen" ]]' },
  'install.browser.zen': { id: 'install.browser.zen', disabled: 'omarchy-pkg-present zen-browser-bin' },
  'plain': { id: 'plain', label: 'No guards' }
}
const script = menu.guardScript(items)
const browserSlot = `\${__omarchy_read_${menu.guardReaders.indexOf('omarchy-default-browser')}}`

assert(
  script.includes('if { omarchy-pkg-present brave-bin; } >/dev/null 2>&1; then echo setup.default.browser.brave:w:1; else echo setup.default.browser.brave:w:0; fi'),
  'guard script reports a when: as <id>:w:<0|1>'
)
assert(
  script.includes('then echo setup.default.browser.zen:c:1; else echo setup.default.browser.zen:c:0; fi'),
  'guard script reports a checked: as <id>:c:<0|1>'
)
assert(
  script.includes('if { omarchy-pkg-present zen-browser-bin; } >/dev/null 2>&1; then echo install.browser.zen:d:1; else echo install.browser.zen:d:0; fi'),
  'guard script reports a disabled: as <id>:d:<0|1>'
)
assert(!/\bplain:[wcd]:/.test(script), 'guard script skips items with nothing to evaluate')
assertEqual(menu.guardScript({ plain: items.plain }), '', 'guard script is empty when no item carries a guard')

// The cost the menu is paying is per fork, not per expression, so what makes
// the batch fast is asking each command once however many rows want it.
assertEqual(
  (script.match(/^__omarchy_read_\d+=\$\(omarchy-default-browser /gm) || []).length,
  1,
  'guard script reads a value command once for the whole batch'
)
assert(
  script.includes(`[[ "${browserSlot}" == "brave" ]]`) && !script.includes('"$(omarchy-default-browser)"'),
  'guard script substitutes the captured answer into the expression'
)
assert(
  script.indexOf('__omarchy_read_') < script.indexOf('if { omarchy-pkg-present'),
  'guard script captures readers before any guard runs, since $() would trap a lazy memo in its subshell'
)

// Substitution is confined to the plain `$(reader)` form on purpose. A
// function shadowing the name would also catch these, and answer them wrong.
const untouched = menu.guardScript({
  a: { id: 'a', when: 'command -v omarchy-dns' },
  b: { id: 'b', when: '[[ "$(OMARCHY_PATH=/usr/share/omarchy omarchy-channel-current)" == "stable" ]]' },
  c: { id: 'c', when: '(( $(omarchy-default-browser | wc -l) == 1 ))' }
})
assert(
  untouched.includes('command -v omarchy-dns')
    && untouched.includes('$(OMARCHY_PATH=/usr/share/omarchy omarchy-channel-current)')
    && untouched.includes('$(omarchy-default-browser | wc -l)'),
  'guard script leaves every form but the plain substitution to run the real command'
)
assert(
  !/^__omarchy_read_/m.test(untouched),
  'guard script captures nothing when no guard uses the plain substitution'
)

// Every reader named in the shipped menu has to be listed, or it silently
// keeps forking once per row that reads it.
const fs = require('fs')
const defaultItems = menu.parseMenuJsonc(fs.readFileSync(path.join(root, 'default/omarchy/omarchy-menu.jsonc'), 'utf8'))
const guardText = defaultItems.map(item => `${item.when}\n${item.checked}\n${item.disabled}`).join('\n')
const repeated = [...new Set(
  (guardText.match(/\$\((omarchy-[a-z0-9-]+)\)/g) || []).map(match => match.slice(2, -1))
)].filter(command => guardText.split(`$(${command})`).length > 2)
assertDeepEqual(
  repeated.filter(command => !menu.guardReaders.includes(command)),
  [],
  'guard readers cover every command the shipped menu reads from more than one row'
)
JS

prelude() {
  node -e '
    const path = require("path")
    const menu = require(path.join(process.env.ROOT, "shell/plugins/menu/MenuModel.js"))
    process.stdout.write(menu.guardScript({ probe: { id: "probe", when: "true" } }))
  ' | command grep -v '^if {'
}

# The prelude shadows the real commands for the length of the batch, so it has
# to answer exactly as they do -- including for arguments no shipped guard
# passes today, which an extension is free to write tomorrow.
stub_dir=$(mktemp -d)
trap 'rm -rf "$stub_dir"' EXIT

# Nothing may ask what is installed: this desktop does not manage packages, and
# a prelude that shelled out to pacman would put a package-database query on the
# path of every menu open. A pacman that fails loudly proves the batch is clean.
cat >"$stub_dir/pacman" <<'STUB'
#!/bin/bash
echo "pacman must never run inside a menu guard batch" >&2
exit 97
STUB
chmod +x "$stub_dir/pacman"
printf '#!/bin/bash\nexit 0\n' >"$stub_dir/gvim"
chmod +x "$stub_dir/gvim"

guard_prelude=$(prelude)

# Arguments reach both sides as argv. Interpolating them into the shadow's
# script text would let `bash>=1` parse as a redirection, so the case that
# exists to prove constraints work would quietly test `bash` instead.
assert_helper_agrees() {
  local description="$1" helper="$2"
  shift 2

  local real=0 shadowed=0
  PATH="$stub_dir:$PATH" "$ROOT/bin/$helper" "$@" >/dev/null 2>&1 || real=$?
  PATH="$stub_dir:$PATH" bash -c "$guard_prelude"$'\n'"$helper \"\$@\"" "$helper" "$@" >/dev/null 2>&1 || shadowed=$?
  ((real == shadowed)) || fail "$description" "$helper $*: real=$real shadowed=$shadowed"
}

[[ $guard_prelude != *pacman* ]] ||
  fail "guard prelude never queries the package database" "$guard_prelude"
pass "guard prelude never queries the package database"

! grep -E '"(when|checked|disabled)":"[^"]*omarchy-pkg-' "$ROOT/default/omarchy/omarchy-menu.jsonc" >/dev/null ||
  fail "no menu guard asks whether a package is installed"
pass "no menu guard asks whether a package is installed"

# cd is a shell builtin `command -v` finds and a PATH search does not.
cmd_cases=("gvim" "cd" "absent" "gvim absent" "gvim cd" "")
for helper in omarchy-cmd-present omarchy-cmd-missing; do
  for case in "${cmd_cases[@]}"; do
    read -r -a argv <<<"$case"
    assert_helper_agrees "guard prelude resolves commands as the real helper does" "$helper" "${argv[@]}"
  done
done
pass "guard prelude resolves commands as omarchy-cmd-present and omarchy-cmd-missing do"

# A reader is replaced by what it printed, which has to compare identically to
# the substitution it stood in for -- including the trailing newline $() drops.
reader_script=$(node -e '
  const path = require("path")
  const menu = require(path.join(process.env.ROOT, "shell/plugins/menu/MenuModel.js"))
  process.stdout.write(menu.guardScript({
    hit: { id: "hit", checked: "[[ \"$(omarchy-dns)\" == \"Cloudflare\" ]]" },
    miss: { id: "miss", checked: "[[ \"$(omarchy-dns)\" == \"Google\" ]]" }
  }))
')
reader_result=$(bash -c '
omarchy-dns() { printf "Cloudflare\n"; }
export -f omarchy-dns
'"$reader_script")
[[ $reader_result == $'hit:c:1\nmiss:c:0' ]] ||
  fail "guard prelude compares a captured reader as the substitution did" "got: $reader_result"
pass "guard prelude compares a captured reader exactly as the substitution it replaced"

# The batch inherits whatever a login shell left set. A reader that exits
# nonzero must not take the rest of the menu's rows down with it.
errexit_result=$(bash -e -c '
omarchy-dns() { printf "Cloudflare\n"; return 3; }
export -f omarchy-dns
'"$reader_script"'
printf "survived\n"' 2>/dev/null)
[[ $errexit_result == $'hit:c:1\nmiss:c:0\nsurvived' ]] ||
  fail "guard batch survives a failing reader under errexit" "got: $errexit_result"
pass "guard batch survives a reader that exits nonzero under errexit"

# Update > Extra Themes runs omarchy-theme-update, which pulls the themes that
# came from a git clone and skips everything else, so the guard has to answer
# for the same set: a row that appears over a symlinked theme or a worktree's
# `.git` file opens a terminal that prints nothing and closes. Both sides ask
# omarchy-theme-extras today; the shapes below are what would tell us if one
# of them stopped.
# The Update menu family is gone, so the guard is the command itself: whatever
# omarchy-theme-extras answers is what omarchy-theme-update will act on.
themes_guard='omarchy-theme-extras'

cat >"$stub_dir/git" <<'STUB'
#!/bin/bash
: "${GIT_CALLS:=/dev/null}"
{ printf '<%s>' "$@"; printf '\n'; } >>"$GIT_CALLS"
STUB
chmod +x "$stub_dir/git"

# The updater names each theme it pulls, so what it printed is what the row
# would have been for. Run the guard the way the batch does, braces and all,
# and say which shapes are meant to show it rather than only that the two
# agree: they read the same command now, and agreement alone would hold even
# if both went wrong together.
assert_themes_guard_agrees() {
  local description="$1" home="$2" expected="$3"
  local guarded=0 updated=0

  HOME="$home" PATH="$ROOT/bin:$PATH" bash -e -c "{ $themes_guard; } >/dev/null 2>&1" || guarded=$?
  [[ -n $(HOME="$home" PATH="$ROOT/bin:$stub_dir:$PATH" "$ROOT/bin/omarchy-theme-update" 2>/dev/null) ]] || updated=1
  ((guarded == expected)) || fail "$description" "$home: guard=$guarded expected=$expected"
  ((updated == expected)) || fail "$description" "$home: update=$updated expected=$expected"
}

themes_home=$(mktemp -d)
trap 'rm -rf "$stub_dir" "$themes_home"' EXIT

# A theme copied by hand has nothing to pull, a symlinked one is someone's
# working copy, and a `.git` file is a worktree living elsewhere.
mkdir -p "$themes_home/missing"
mkdir -p "$themes_home/empty/.config/omarchy/themes"
mkdir -p "$themes_home/copied/.config/omarchy/themes/handmade"
mkdir -p "$themes_home/cloned/.config/omarchy/themes/tokyo-night/.git"
mkdir -p "$themes_home/linked/.config/omarchy/themes" "$themes_home/checkout/.git"
ln -s "$themes_home/checkout" "$themes_home/linked/.config/omarchy/themes/in-progress"
mkdir -p "$themes_home/worktree/.config/omarchy/themes/branch"
printf 'gitdir: /elsewhere\n' >"$themes_home/worktree/.config/omarchy/themes/branch/.git"

for shape in missing:1 empty:1 copied:1 cloned:0 linked:1 worktree:1; do
  assert_themes_guard_agrees \
    "omarchy-theme-extras answers exactly when omarchy-theme-update has something to pull" \
    "$themes_home/${shape%:*}" "${shape#*:}"
done
pass "omarchy-theme-extras answers exactly when omarchy-theme-update has something to pull"

# Which themes get pulled, not just that something did: a name with a space in
# it is the one that goes missing the moment a path is split rather than passed
# whole, and it would still print an Updating: line on its way to the wrong
# directory.
many="$themes_home/many/.config/omarchy/themes"
mkdir -p "$many/tokyo night/.git" "$many/zen/.git" "$many/handmade"
ln -s "$themes_home/checkout" "$many/in-progress"

listed=$(HOME="$themes_home/many" LC_ALL=C "$ROOT/bin/omarchy-theme-extras")
[[ $listed == "$many/tokyo night"$'\n'"$many/zen" ]] ||
  fail "omarchy-theme-extras lists every clone and nothing else" "got: $listed"
pass "omarchy-theme-extras lists every clone and nothing else"

git_calls=$(mktemp)
trap 'rm -rf "$stub_dir" "$themes_home" "$git_calls"' EXIT
HOME="$themes_home/many" LC_ALL=C GIT_CALLS="$git_calls" PATH="$ROOT/bin:$stub_dir:$PATH" \
  "$ROOT/bin/omarchy-theme-update" >/dev/null 2>&1
pulled=$(<"$git_calls")
[[ $pulled == "<-C><$many/tokyo night><pull>"$'\n'"<-C><$many/zen><pull>" ]] ||
  fail "omarchy-theme-update pulls each clone by its whole path" "got: $pulled"
pass "omarchy-theme-update pulls each clone by its whole path"
