local paths = require("default.hypr.paths")
local require_optional = require("default.hypr.require_optional")


-- Cursor size, unless the session already set one. The host's cursor size is
-- the user's choice and lives in gtk settings.ini and the environment; a
-- desktop that overwrote it would resize their pointer for picking it.
local function env_default(name, value)
  local current = os.getenv(name)
  if current == nil or current == "" then
    hl.env(name, value)
  end
end

env_default("XCURSOR_SIZE", "24")
env_default("HYPRCURSOR_SIZE", "24")

-- Force all apps to use Wayland.
hl.env("GDK_BACKEND", "wayland,x11,*")
hl.env("QT_QPA_PLATFORM", "wayland;xcb")
-- The Qt platform theme decides which style and icon theme every Qt app in the
-- session gets, including omarchy-shell itself. It was left unset here on the
-- reasoning that the host configures it through qt6ct -- but qt6ct only loads
-- when this names it. Unset means Qt loads no platform theme at all and reads
-- none of that configuration, so a host with icon_theme=Papirus in qt6ct.conf
-- still got Qt's built-in fallback icons.
--
-- env_default, so a host that has already chosen (kdeglobals, gtk3, a different
-- qt6ct generation) keeps its choice.
env_default("QT_QPA_PLATFORMTHEME", "qt6ct")
hl.env("MOZ_ENABLE_WAYLAND", "1")
hl.env("ELECTRON_OZONE_PLATFORM_HINT", "wayland")
hl.env("OZONE_PLATFORM", "wayland")
hl.env("XDG_SESSION_TYPE", "wayland")

-- Allow better support for screen sharing (Google Meet, Discord, etc).
hl.env("XDG_CURRENT_DESKTOP", "Hyprland")
hl.env("XDG_SESSION_DESKTOP", "Hyprland")

-- Use XCompose file.
hl.env("XCOMPOSEFILE", paths.home .. "/.XCompose")

-- hyprctl setenv doesn't reach keybind dispatcher env; use hl.env.
hl.env("OMARCHY_PATH", paths.omarchy_path)

hl.env("OMARCHY_SESSION_CONFIG_HOME", paths.config_home)
hl.env("OMARCHY_SESSION_STATE_HOME", paths.state_home)
hl.env("OMARCHY_SESSION_CACHE_HOME", paths.cache_home)
hl.env("OMARCHY_SESSION_DATA_HOME", paths.data_home)

hl.env("OMARCHY_CONFIG_HOME", paths.omarchy_config_home)
hl.env("OMARCHY_STATE_HOME", paths.omarchy_state_home)
hl.env("OMARCHY_CACHE_HOME", paths.omarchy_cache_home)
hl.env("OMARCHY_DATA_HOME", paths.omarchy_data_home)

local bin_dir = paths.omarchy_path .. "/bin"
local kept = {}
for entry in (os.getenv("PATH") or "/usr/local/bin:/usr/bin"):gmatch("[^:]+") do
  if entry ~= bin_dir then table.insert(kept, entry) end
end
table.insert(kept, 1, bin_dir)
hl.env("PATH", table.concat(kept, ":"))

-- Hardware-specific environment.
require("default.hypr.nvidia")

hl.config({
  xwayland = {
    force_zero_scaling = true,
  },

  ecosystem = {
    no_update_news = true,
  },
})
