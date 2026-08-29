-- Shared path constants for Omarchy's Hyprland Lua modules.
-- Lua files loaded with require() have separate local scopes, so modules that
-- need these paths import this table instead of repeating os.getenv() lookups.

local home = os.getenv("HOME")

-- A variable that is set but empty means "unset" (XDG Base Directory spec);
-- bash's ${VAR:-fallback} in the sibling tools treats it the same way.
local function env_or(name, fallback)
  local value = os.getenv(name)
  if value == nil or value == "" then
    return fallback
  end
  return value
end

local config_home =
  env_or("OMARCHY_SESSION_CONFIG_HOME",
    env_or("XDG_CONFIG_HOME", home .. "/.config"))

local state_home =
  env_or("OMARCHY_SESSION_STATE_HOME",
    env_or("XDG_STATE_HOME", home .. "/.local/state"))

local cache_home =
  env_or("OMARCHY_SESSION_CACHE_HOME",
    env_or("XDG_CACHE_HOME", home .. "/.cache"))

local data_home =
  env_or("OMARCHY_SESSION_DATA_HOME",
    env_or("XDG_DATA_HOME", home .. "/.local/share"))

return {
  home = home,

  config_home = config_home,
  state_home = state_home,
  cache_home = cache_home,
  data_home = data_home,

  omarchy_config_home =
    env_or("OMARCHY_CONFIG_HOME", config_home .. "/omarchy"),

  omarchy_state_home =
    env_or("OMARCHY_STATE_HOME", state_home .. "/omarchy"),

  omarchy_cache_home =
    env_or("OMARCHY_CACHE_HOME", cache_home .. "/omarchy"),

  omarchy_data_home =
    env_or("OMARCHY_DATA_HOME", data_home .. "/omarchy"),

  omarchy_path = assert(os.getenv("OMARCHY_PATH"), "OMARCHY_PATH is unset"),
}
