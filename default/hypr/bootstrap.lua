-- Hyprland bootstrap for Omarchy's Lua module path.

local home = os.getenv("HOME")

local function env_or(name, fallback)
  local value = os.getenv(name)
  if value == nil or value == "" then
    return fallback
  end
  return value
end

local config_home = env_or("OMARCHY_SESSION_CONFIG_HOME", home .. "/.config")
local state_home = env_or("OMARCHY_SESSION_STATE_HOME", home .. "/.local/state")

local reload_prefixes = {
  "default.hypr",
  "hypr",
  "omarchy.current.theme",
}

local function should_reload_module(module)
  for _, prefix in ipairs(reload_prefixes) do
    if module == prefix or module:sub(1, #prefix + 1) == prefix .. "." then
      return true
    end
  end

  return false
end

local modules_to_reload = {}
for module in pairs(package.loaded) do
  if should_reload_module(module) then
    table.insert(modules_to_reload, module)
  end
end

for _, module in ipairs(modules_to_reload) do
  package.loaded[module] = nil
end

-- Load generated state and user modules from the active Omarchy session
-- roots, then Omarchy defaults from $OMARCHY_PATH.
package.path = state_home
  .. "/?.lua;"
  .. config_home
  .. "/?.lua;"
  .. assert(os.getenv("OMARCHY_PATH"), "OMARCHY_PATH is unset")
  .. "/?.lua;"
  .. package.path
