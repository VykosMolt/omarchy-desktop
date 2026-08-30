#!/bin/bash

set -euo pipefail

# Five commands join a caller-supplied name into a path they write, delete or
# execute. Four of them did it unchecked: `omarchy-hook ../../../../pwned` ran a
# script four directories above the hooks directory, `omarchy-hyprland-toggle
# ../../../../../victim off` deleted a .lua file five above the toggles one, and
# omarchy-toggle and omarchy-state created files outside the state root. Each
# check here is the escape that worked, so a guard that stops working shows up
# as a file appearing, disappearing, or running where it should not.

source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)/base-test.sh"

test_tmp=$(mktemp -d)
trap 'rm -rf "$test_tmp"' EXIT

test_home="$test_tmp/home"
mkdir -p "$test_home"

stub_bin="$test_tmp/bin"
mkdir -p "$stub_bin"
printf '#!/bin/bash\nexit 0\n' >"$stub_bin/hyprctl"
chmod +x "$stub_bin/hyprctl"

run() {
  HOME="$test_home" PATH="$stub_bin:$ROOT/bin:$PATH" OMARCHY_PATH="$ROOT" \
    bash "$ROOT/bin/$1" "${@:2}" >"$test_tmp/out" 2>&1
}

# omarchy-toggle wrote $HOME/pwned-toggle from four levels above its toggles
# directory.
if run omarchy-toggle "../../../../pwned-toggle" on; then
  fail "omarchy-toggle refuses a climbing flag name" "$(cat "$test_tmp/out")"
fi
[[ ! -e $test_home/pwned-toggle ]] || fail "omarchy-toggle writes nothing outside its toggles directory"

run omarchy-toggle example on || fail "omarchy-toggle still accepts a plain flag name" "$(cat "$test_tmp/out")"
[[ -f $test_home/.local/state/omarchy/toggles/example ]] || fail "omarchy-toggle still sets a plain flag"

pass "a toggle name cannot climb out of the toggles directory"

# omarchy-state wrote a file two levels above $HOME.
if run omarchy-state set "../../../../pwned-state"; then
  fail "omarchy-state refuses a climbing state name" "$(cat "$test_tmp/out")"
fi
[[ ! -e $test_tmp/pwned-state ]] || fail "omarchy-state writes nothing outside the state root"

run omarchy-state set example || fail "omarchy-state still accepts a plain state name" "$(cat "$test_tmp/out")"
[[ -f $test_home/.local/state/omarchy/example ]] || fail "omarchy-state still sets a plain state"

# clear takes a glob, so the guard must not refuse the pattern characters it needs.
run omarchy-state clear 'exampl?' || fail "omarchy-state still accepts a clear pattern" "$(cat "$test_tmp/out")"
[[ ! -e $test_home/.local/state/omarchy/example ]] || fail "omarchy-state still clears by pattern"

pass "a state name cannot climb out of the state root, and a glob still clears"

# omarchy-hyprland-toggle deleted any .lua file it was pointed at, once its own
# toggles directory existed for the relative path to resolve through.
mkdir -p "$test_home/.local/state/omarchy/toggles/hypr"
printf 'precious\n' >"$test_home/victim.lua"
if run omarchy-hyprland-toggle "../../../../../victim" off; then
  fail "omarchy-hyprland-toggle refuses a climbing flag name" "$(cat "$test_tmp/out")"
fi
[[ -f $test_home/victim.lua ]] || fail "omarchy-hyprland-toggle deletes nothing outside its toggles directory"

pass "a Hyprland flag name cannot delete a file outside the toggles directory"

# omarchy-hook ran the script it resolved to, which is worse than writing one.
printf '#!/bin/bash\nprintf ran >"%s/hook-ran"\n' "$test_tmp" >"$test_tmp/pwned-hook"
mkdir -p "$test_home/.config/omarchy/hooks"
if run omarchy-hook "../../../../pwned-hook"; then
  fail "omarchy-hook refuses a climbing hook name" "$(cat "$test_tmp/out")"
fi
[[ ! -e $test_tmp/hook-ran ]] || fail "omarchy-hook runs nothing outside the hooks directory"

printf '#!/bin/bash\nprintf "%%s" "$1" >"%s/hook-arg"\n' "$test_tmp" >"$test_home/.config/omarchy/hooks/example"
run omarchy-hook example passed || fail "omarchy-hook still runs a plain hook name" "$(cat "$test_tmp/out")"
[[ $(cat "$test_tmp/hook-arg") == "passed" ]] || fail "omarchy-hook still forwards its arguments"

pass "a hook name cannot run a script outside the hooks directory"

# omarchy-done already refused a climbing name; it now shares the rule, so the
# names it always accepted have to keep working.
if run omarchy-done mark "../pwned-done"; then
  fail "omarchy-done refuses a climbing marker name" "$(cat "$test_tmp/out")"
fi
[[ ! -e $test_home/.local/state/omarchy/pwned-done ]] || fail "omarchy-done writes nothing outside its done directory"

run omarchy-done mark example || fail "omarchy-done still marks a plain name" "$(cat "$test_tmp/out")"
run omarchy-done check example || fail "omarchy-done still checks a plain name" "$(cat "$test_tmp/out")"

# A name that merely starts with dots is an ordinary filename, not a climb, and
# the rule is written to leave it alone.
run omarchy-done mark "..leading" || fail "omarchy-done accepts a name that only starts with dots" "$(cat "$test_tmp/out")"
[[ -f $test_home/.local/state/omarchy/done/..leading ]] || fail "omarchy-done marks a name that only starts with dots"

pass "a done marker name is held to the same rule and ordinary names still pass"
