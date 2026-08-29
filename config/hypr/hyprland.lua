-- Learn how to configure Hyprland: https://wiki.hypr.land/Configuring/Start/

-- Omarchy's bootstrap keeps path setup out of this user config. There is no
-- packaged install to fall back on, so an unset OMARCHY_PATH means this config
-- was not started through omarchy-arch-session: say so rather than loading a
-- half-configured desktop.
local omarchy_path = os.getenv("OMARCHY_PATH")
if omarchy_path == nil or omarchy_path == "" then
  error("OMARCHY_PATH is unset; start this session with omarchy-arch-session")
end
dofile(omarchy_path .. "/default/hypr/bootstrap.lua")

-- Disable all Omarchy default bindings. Add your own in hypr/bindings.lua.
-- omarchy_default_bindings = false
--
-- Or disable only bindings for Omarchy's preinstalled apps/web apps while
-- keeping core window-manager bindings:
-- omarchy_preinstalled_bindings = false

-- Load Omarchy defaults.
require("default.hypr.omarchy")

-- Put your personal overrides in these files. They're loaded after Omarchy's
-- defaults so package updates can improve the defaults without rewriting your
-- files under the active Omarchy session config root.
require("hypr.monitors")
require("hypr.input")
require("hypr.bindings")
require("hypr.looknfeel")
require("hypr.autostart")

-- Toggle config flags dynamically.
require("default.hypr.toggles")

-- Add any other personal Hyprland configuration below.
-- o.window("qemu", { workspace = "5" })
