-- Disable a Hyprland input device whose name was stored as data, not Lua.
-- Device names come from USB descriptors and must never be loaded as code.

local paths = require("default.hypr.paths")

return function(kind)
  local file = io.open(
    paths.omarchy_state_home .. "/toggles/hypr/" .. kind .. "-disabled-name",
    "r"
  )
  if not file then
    return
  end

  local name = file:read("*l")
  file:close()

  if name and name ~= "" then
    hl.device({ name = name, enabled = false })
  end
end
