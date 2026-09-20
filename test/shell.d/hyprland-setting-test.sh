#!/bin/bash

# omarchy-hyprland-setting is the only way the settings panel reaches a
# Hyprland option, so what matters here is that it writes the way this
# compositor can be written to, that it never records a value the compositor
# did not accept, that it records it as the type Hyprland answers with, and
# that default/hypr/settings.lua hands that record back as the nested tables
# hl.config expects.
#
# The stub below answers `keyword` exactly as the real hyprctl does under a Lua
# config -- by refusing. An earlier stub answered it with "ok", and on that
# stub a command that set nothing at all on the real machine passed every test
# here.

set -euo pipefail

source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)/base-test.sh"

require_command lua
require_command jq

tmpdir=$(mktemp -d "${TMPDIR:-/tmp}/omarchy-hyprland-setting.XXXXXX")
trap 'rm -rf "$tmpdir"' EXIT

mkdir -p "$tmpdir/bin" "$tmpdir/config"

cat > "$tmpdir/bin/hyprctl" <<'STUB'
#!/bin/bash
printf '%s\n' "$*" >> "$HYPRCTL_LOG"
case "$1 $2" in
  "getoption decoration:rounding") echo '{"option": "decoration:rounding", "int": 0, "set": true }' ;;
  "getoption animations:enabled") echo '{"option": "animations:enabled", "bool": true, "set": true }' ;;
  "getoption general:gaps_in") echo '{"option": "general:gaps_in", "css": "5 5 5 5", "set": true }' ;;
  "getoption general:layout") echo '{"option": "general:layout", "str": "dwindle", "set": true }' ;;
  "getoption input:touchpad:natural_scroll") echo '{"option": "input:touchpad:natural_scroll", "bool": false, "set": true }' ;;
  "getoption input:touchpad:tap-to-click") echo '{"option": "input:touchpad:tap-to-click", "bool": true, "set": false }' ;;
  "getoption decoration:active_opacity") echo '{"option": "decoration:active_opacity", "float": 1.000000, "set": false }' ;;
  getoption*) echo "no such option" ;;
  # What the real hyprctl says under this session's Lua config. Nothing is set.
  keyword*) echo "keyword can't work with non-legacy parsers. Use eval." ;;
  eval*)
    if [[ -n ${HYPRCTL_REFUSE:-} && $* == *"$HYPRCTL_REFUSE"* ]]; then
      echo "error: unknown config key"
    else
      echo ok
    fi
    ;;
  reload*) echo ok ;;
esac
exit 0
STUB
chmod +x "$tmpdir/bin/hyprctl"

export OMARCHY_PATH="$ROOT"
export OMARCHY_CONFIG_HOME="$tmpdir/config"
export HYPRCTL_LOG="$tmpdir/hyprctl.log"
export PATH="$tmpdir/bin:$ROOT/bin:$PATH"
: > "$HYPRCTL_LOG"

store="$tmpdir/config/hyprland.json"

# ------------------------------------------------------------------ reading

[[ $(omarchy-hyprland-setting get animations:enabled) == "true" ]] ||
  fail "a bool option reads back as a bool"
[[ $(omarchy-hyprland-setting get general:layout) == "dwindle" ]] ||
  fail "a string option reads back as its string"
[[ $(omarchy-hyprland-setting get general:gaps_in) == "5 5 5 5" ]] ||
  fail "a css option reads back the way Hyprland spells it"
[[ $(omarchy-hyprland-setting get decoration:active_opacity) == "1" ]] ||
  fail "a float option reads back as a number"
pass "every option kind hyprctl answers with reads back"

# hyprctl says "no such option" on stdout and still exits 0, so the shape of
# the answer is what has to be checked rather than the exit status.
if omarchy-hyprland-setting get nonsense:key >/dev/null 2>&1; then
  fail "an unknown option is an error, not an empty answer"
fi
pass "an unknown option is reported rather than swallowed"

# ------------------------------------------------------------------ writing

omarchy-hyprland-setting set decoration:rounding 8 >/dev/null
omarchy-hyprland-setting set animations:enabled false >/dev/null
omarchy-hyprland-setting set general:gaps_in 12 >/dev/null
omarchy-hyprland-setting set general:layout master >/dev/null
omarchy-hyprland-setting set input:touchpad:natural_scroll true >/dev/null

[[ $(jq -c . "$store") == '{"animations:enabled":false,"decoration:rounding":8,"general:gaps_in":12,"general:layout":"master","input:touchpad:natural_scroll":true}' ]] ||
  fail "each option is recorded as the type Hyprland answers with" "$(cat "$store")"
pass "the record carries types, not the text that was typed"

grep -Fqx "eval hl.config({ decoration = { rounding = 8 } })" "$HYPRCTL_LOG" ||
  fail "a write reaches the compositor as the Lua its config provider takes" "$(cat "$HYPRCTL_LOG")"
grep -Fqx "eval hl.config({ animations = { enabled = false } })" "$HYPRCTL_LOG" ||
  fail "a bool is written as Lua's own true or false, not as a string"
grep -Fqx "eval hl.config({ general = { layout = \"master\" } })" "$HYPRCTL_LOG" ||
  fail "a string is written as a quoted Lua string"
if grep -q '^keyword' "$HYPRCTL_LOG"; then
  fail "nothing is written with keyword, which this compositor refuses outright"
fi
pass "a write reaches the running compositor as Lua, never as a keyword"

# hyprctl reads this option back under a dashed name and its Lua provider knows
# it only by the underscored one, so the two spellings have to be kept apart.
omarchy-hyprland-setting set input:touchpad:tap-to-click false >/dev/null
grep -Fqx "eval hl.config({ input = { touchpad = { tap_to_click = false } } })" "$HYPRCTL_LOG" ||
  fail "a dashed option is written under the name the Lua provider knows" "$(cat "$HYPRCTL_LOG")"
[[ $(jq -r '."input:touchpad:tap-to-click"' "$store") == "false" ]] ||
  fail "a dashed option is recorded under the name hyprctl reads it back by"
pass "an option spelled one way for reads and another for writes is written correctly"

# A value hyprctl refuses must leave no trace: the record is what comes back
# after a reload, and recording a rejected value would apply it for real.
before=$(cat "$store")
HYPRCTL_REFUSE=rounding omarchy-hyprland-setting set decoration:rounding 9 >/dev/null 2>&1 &&
  fail "a refused write is an error"
[[ $(cat "$store") == "$before" ]] || fail "a refused write is not recorded"
pass "a value the compositor refused is never recorded"

omarchy-hyprland-setting set decoration:rounding notanumber >/dev/null 2>&1 &&
  fail "a value of the wrong type is an error"
[[ $(cat "$store") == "$before" ]] || fail "a wrongly typed value is not recorded"
grep -Fq "notanumber" "$HYPRCTL_LOG" &&
  fail "a wrongly typed value never reaches the compositor"
pass "a value of the wrong type is refused before hyprctl sees it"

omarchy-hyprland-setting set nonsense:key 1 >/dev/null 2>&1 &&
  fail "an unknown option cannot be written"
pass "an unknown option cannot be written"

# ----------------------------------------------------------------- resetting

omarchy-hyprland-setting reset general:layout >/dev/null
jq -e 'has("general:layout")' "$store" >/dev/null &&
  fail "reset drops the option from the record"
grep -Fqx "reload" "$HYPRCTL_LOG" ||
  fail "reset reloads Hyprland so the config files get the key back"
pass "reset hands an option back to the config files"

# -------------------------------------------------------------------- replay

expected=$(printf '%s\n' \
  'animations:enabled	boolean	false' \
  'decoration:rounding	number	8' \
  'general:gaps_in	number	12' \
  'input:touchpad:natural_scroll	boolean	true' \
  'input:touchpad:tap-to-click	boolean	false')
[[ $(omarchy-hyprland-setting list --tsv) == "$expected" ]] ||
  fail "the replay format names each value's type" "$(omarchy-hyprland-setting list --tsv)"
pass "the replay format names each value's type"

replayed=$(lua <<'LUA'
package.path = os.getenv("OMARCHY_PATH") .. "/?.lua;" .. package.path

local applied = {}

local function flatten(prefix, tree)
  for key, value in pairs(tree) do
    local name = prefix == "" and key or (prefix .. ":" .. key)
    if type(value) == "table" then
      flatten(name, value)
    else
      applied[#applied + 1] = name .. "=" .. tostring(value) .. " (" .. type(value) .. ")"
    end
  end
end

hl = {
  config = function(tree)
    flatten("", tree)
  end,
}

-- No helpers: the replay is required from toggles.lua, which some callers
-- load without them, so it has to stand on its own.
require("default.hypr.settings")

table.sort(applied)
print(table.concat(applied, "\n"))
LUA
)

expected_replay=$(printf '%s\n' \
  'animations:enabled=false (boolean)' \
  'decoration:rounding=8 (number)' \
  'general:gaps_in=12 (number)' \
  'input:touchpad:natural_scroll=true (boolean)' \
  'input:touchpad:tap-to-click=false (boolean)')
[[ $replayed == "$expected_replay" ]] ||
  fail "the replay hands Hyprland nested tables of the right types" "$replayed"
pass "the replay hands Hyprland nested tables of the right types"

# With nothing recorded the replay still runs, and has to come out of it
# having set nothing: this module parses as part of the Hyprland config, so
# anything it gets wrong on the empty path costs the whole desktop.
rm -f "$store"
quiet=$(lua <<'LUA'
package.path = os.getenv("OMARCHY_PATH") .. "/?.lua;" .. package.path

local keys = 0
hl = {
  config = function(tree)
    for _ in pairs(tree) do
      keys = keys + 1
    end
  end,
}

require("default.hypr.settings")

print(keys)
LUA
)
[[ $quiet == "0" ]] || fail "an empty record configures nothing" "$quiet"
pass "an empty record configures nothing"
