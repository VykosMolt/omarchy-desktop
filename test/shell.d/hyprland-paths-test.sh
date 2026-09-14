#!/bin/bash

set -euo pipefail

source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)/base-test.sh"

require_command lua

run_paths() {
  lua - <<'LUA'
package.path = os.getenv("OMARCHY_PATH") .. "/?.lua;" .. package.path
local paths = require("default.hypr.paths")
assert(paths.config_home == os.getenv("EXPECTED_CONFIG"), "config_home: " .. paths.config_home)
assert(paths.state_home == os.getenv("EXPECTED_STATE"), "state_home: " .. paths.state_home)
LUA
}

HOME="/home/test-user" OMARCHY_PATH="$ROOT" \
  XDG_CONFIG_HOME= XDG_STATE_HOME= \
  EXPECTED_CONFIG="/home/test-user/.config" EXPECTED_STATE="/home/test-user/.local/state" \
  run_paths
pass "empty XDG path variables fall back to their defaults"

HOME="/home/test-user" OMARCHY_PATH="$ROOT" \
  XDG_CONFIG_HOME="/custom/config" XDG_STATE_HOME="/custom/state" \
  EXPECTED_CONFIG="/custom/config" EXPECTED_STATE="/custom/state" \
  run_paths
pass "set XDG path variables are honored"

# The bootstrap must use the same XDG/session roots as paths.lua, and repeated
# reloads must not grow package.path or leave cached configuration modules live.
OMARCHY_PATH="$ROOT" XDG_CONFIG_HOME=/custom/config XDG_STATE_HOME=/custom/state lua - <<'LUA'
local bootstrap = os.getenv("OMARCHY_PATH") .. "/default/hypr/bootstrap.lua"
local original = package.path
dofile(bootstrap)
local expected = "/custom/state/?.lua;/custom/config/?.lua;" .. os.getenv("OMARCHY_PATH") .. "/?.lua;" .. original
assert(package.path == expected, "bootstrap ignores XDG roots")
for i = 1, 100 do
  package.loaded["hypr.bindings"] = true
  dofile(bootstrap)
  assert(package.path == expected, "reload accumulates search paths")
  assert(package.loaded["hypr.bindings"] == nil, "reload keeps stale config")
end
LUA
pass "bootstrap honors XDG roots and reloads without accumulating paths"

state_fixture=$(mktemp -d)
trap 'rm -rf "$state_fixture"' EXIT
mkdir -p "$state_fixture/custom-state/workspace-layouts" "$state_fixture/custom-state/current/theme"
printf '%s\n' 'workspace_loads = (workspace_loads or 0) + 1' > "$state_fixture/custom-state/workspace-layouts/1.lua"
printf '%s\n' 'theme_loads = (theme_loads or 0) + 1' > "$state_fixture/custom-state/current/theme/hyprland.lua"
OMARCHY_PATH="$ROOT" OMARCHY_STATE_HOME="$state_fixture/custom-state" lua - <<'LUA'
package.path = os.getenv("OMARCHY_PATH") .. "/?.lua;" .. package.path
local original = package.path
local optional = require("default.hypr.require_optional")
for i = 1, 2 do
  optional.file(os.getenv("OMARCHY_STATE_HOME") .. "/current/theme/hyprland.lua")
  dofile(os.getenv("OMARCHY_PATH") .. "/default/hypr/workspace-layouts.lua")
end
assert(theme_loads == 2 and workspace_loads == 2, "custom state paths fail or reuse stale modules")
assert(package.path == original, "state modules pollute the module search path")
optional.file(os.getenv("OMARCHY_STATE_HOME") .. "/missing.lua")
local file = assert(io.open(os.getenv("OMARCHY_STATE_HOME") .. "/broken.lua", "w"))
file:write('error("theme fixture error")')
file:close()
local ok, err = pcall(optional.file, os.getenv("OMARCHY_STATE_HOME") .. "/broken.lua")
assert(not ok and err:find("theme fixture error", 1, true), "broken existing theme errors are hidden")
LUA
pass "custom state roots load fresh theme and workspace files without path changes"
