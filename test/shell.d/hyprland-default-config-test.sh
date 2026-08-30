#!/bin/bash

source "$(dirname "${BASH_SOURCE[0]}")/base-test.sh"

require_command lua

run_application_bindings() {
  local home="$1"
  local prelude="${2:-}"

  HOME="$home" XDG_CONFIG_HOME="$home/.config" XDG_STATE_HOME="$home/.local/state" OMARCHY_PATH="$ROOT" OMARCHY_BINDING_PRELUDE="$prelude" lua <<'LUA'
package.path = os.getenv("HOME") .. "/.config/?.lua;" .. os.getenv("OMARCHY_PATH") .. "/?.lua;" .. package.path

local prelude = os.getenv("OMARCHY_BINDING_PRELUDE") or ""
if prelude ~= "" then
  assert(load(prelude))()
end

hl = {
  dsp = {
    exec_cmd = function(command)
      return { kind = "exec", arg = command }
    end,
  },
  bind = function(keys, dispatcher, opts)
    opts = opts or {}
    if opts.description then
      print(keys .. "\t" .. opts.description)
    end
  end,
}

require("default.hypr.helpers")
require("default.hypr.bindings.applications")
LUA
}

run_omarchy_bindings() {
  local home="$1"
  local prelude="${2:-}"

  HOME="$home" XDG_CONFIG_HOME="$home/.config" XDG_STATE_HOME="$home/.local/state" OMARCHY_PATH="$ROOT" OMARCHY_BINDING_PRELUDE="$prelude" lua <<'LUA'
package.path = os.getenv("HOME") .. "/.config/?.lua;" .. os.getenv("OMARCHY_PATH") .. "/?.lua;" .. package.path

local function proxy()
  return setmetatable({}, {
    __index = function(self, key)
      local value = proxy()
      rawset(self, key, value)
      return value
    end,
    __call = function()
      return {}
    end,
  })
end

local prelude = os.getenv("OMARCHY_BINDING_PRELUDE") or ""
if prelude ~= "" then
  assert(load(prelude))()
end

hl = setmetatable({
  dsp = proxy(),
  bind = function(keys, dispatcher, opts)
    opts = opts or {}
    if opts.description then
      print(keys .. "\t" .. opts.description)
    end
  end,
  config = function() end,
  env = function() end,
  monitor = function() end,
  window_rule = function() end,
  workspace_rule = function() end,
  layer_rule = function() end,
  gesture = function() end,
  animation = function() end,
  curve = function() end,
  exec_cmd = function() end,
  dispatch = function() end,
  on = function() end,
  timer = function() end,
  get_config = function() return nil end,
  get_active_window = function() return nil end,
}, {
  __index = function()
    return function()
      return {}
    end
  end,
})

require("default.hypr.omarchy")
LUA
}

tmpdir=$(mktemp -d)
trap 'rm -rf "$tmpdir"' EXIT

fresh_home="$tmpdir/fresh-home"
mkdir -p "$fresh_home"
fresh_output=$(run_application_bindings "$fresh_home")
grep -Fq $'SUPER + RETURN	Terminal' <<<"$fresh_output" || fail "default application bindings include essentials"
pass "default application bindings load from package defaults"

grep -F 'hl.dsp.send_key_state({ mods = mods, key = key, state = "down" })' "$ROOT/default/hypr/bindings/clipboard.lua" >/dev/null ||
  fail "universal clipboard shortcuts send explicit mods to the focused surface"
pass "universal clipboard shortcuts send explicit mods to the focused surface"

if grep -E 'send_key_state\(\{[^}]*window' "$ROOT/default/hypr/bindings/clipboard.lua" >/dev/null; then
  fail "universal clipboard shortcuts do not target only normal windows"
fi
pass "universal clipboard shortcuts do not exclude layer-shell fields"

if grep -F 'wtype -M' "$ROOT/default/hypr/bindings/clipboard.lua" >/dev/null; then
  fail "universal clipboard shortcuts avoid the virtual keyboard so held SUPER cannot merge in"
fi
pass "universal clipboard shortcuts avoid virtual keyboard modifier merging"

# Omarchy's preinstalled app and web app bindings are gone: they bound this
# desktop's keys to one person's choice of services -- SUPER+SHIFT+S opened
# Google Maps -- and there is no opt-out flag any more because there is nothing
# to opt out of. Named individually so a reintroduction is caught by name.
default_output=$(run_application_bindings "$tmpdir/default-home")
for gone in ChatGPT Grok Calendar Email YouTube WhatsApp "Google Messages" \
  "Google Photos" "Google Maps" "X Post" Obsidian Omawrite "Music TUI" Docker Herdr Tmux; do
  if grep -Fq "	$gone" <<<"$default_output"; then
    fail "no preinstalled application binding survives: $gone"
  fi
done
pass "no preinstalled application or web app binding survives"

grep -Fq $'SUPER + RETURN	Terminal' <<<"$default_output" ||
  fail "the essential application bindings are kept"
pass "the essential application bindings are kept"

no_bindings_home="$tmpdir/no-bindings-home"
mkdir -p "$no_bindings_home"
no_bindings_output=$(run_omarchy_bindings "$no_bindings_home" 'omarchy_default_bindings = false')
[[ -z $no_bindings_output ]] || fail "default binding variable disables all Omarchy bindings" "$no_bindings_output"
pass "default binding variable disables all Omarchy bindings"

# The Grave shortcuts are aliases, so the original SUPER + S pair has to keep
# working alongside them.
scratchpad_home="$tmpdir/scratchpad-home"
mkdir -p "$scratchpad_home"
scratchpad_output=$(run_omarchy_bindings "$scratchpad_home")
grep -Fqx $'SUPER + S	Toggle scratchpad' <<<"$scratchpad_output" ||
  fail "scratchpad keeps its existing toggle binding"
grep -Fqx $'SUPER + grave	Toggle scratchpad' <<<"$scratchpad_output" ||
  fail "scratchpad supports a Quake-style toggle binding"
grep -Fqx $'SUPER + ALT + S	Move window to scratchpad' <<<"$scratchpad_output" ||
  fail "scratchpad keeps its existing move binding"
grep -Fqx $'SUPER + SHIFT + grave	Move window to scratchpad' <<<"$scratchpad_output" ||
  fail "scratchpad supports a Quake-style move binding"
pass "scratchpad retains existing bindings and adds Grave shortcuts"

# The panel hotkeys claim a row of keys that workspace switching already uses
# under other modifiers, so the count matters as much as the bindings: a tenth
# claim on SUPER + CTRL + a number is a collision with one of these.
panels_home="$tmpdir/panels-home"
mkdir -p "$panels_home"
panels_output=$(run_omarchy_bindings "$panels_home")
for panel in 1 2 3 4 5 6 7 8 9; do
  grep -Fqx "SUPER + CTRL + code:$((panel + 9))"$'\t'"Bar panel $panel" <<<"$panels_output" ||
    fail "bar panel hotkeys count the right section" "$panel"
done
number_claims=$(cut -f1 <<<"$panels_output" | grep -cE '^SUPER \+ CTRL \+ code:1[0-9]$' || true)
(( number_claims == 9 )) ||
  fail "only the bar panel hotkeys bind SUPER + CTRL + a number" "$number_claims"
pass "bar panel hotkeys bind SUPER + CTRL + a number without a collision"
