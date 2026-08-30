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
