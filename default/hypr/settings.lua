-- Replays the Hyprland options omarchy-hyprland-setting has recorded.
--
-- The settings panel writes through hyprctl, so a value it sets is already
-- live; this is what puts it back after a reload. It has to run after every
-- other config file, which is why config/hypr/hyprland.lua requires it last
-- (through default.hypr.toggles): otherwise hypr/looknfeel.lua or
-- hypr/input.lua would set the same key afterwards and quietly undo the panel.

local paths = require("default.hypr.paths")

-- "input:touchpad:natural_scroll" is the name Hyprland gives the option and
-- the name the record uses; hl.config wants it as nested tables.
local function assign(tree, key, value)
  local parts = {}

  for part in key:gmatch("[^:]+") do
    parts[#parts + 1] = part
  end

  if #parts == 0 then
    return
  end

  local node = tree

  for index = 1, #parts - 1 do
    local name = parts[index]
    if type(node[name]) ~= "table" then
      node[name] = {}
    end
    node = node[name]
  end

  node[parts[#parts]] = value
end

local function typed(kind, value)
  if kind == "boolean" then
    return value == "true"
  elseif kind == "number" then
    return tonumber(value)
  else
    return value
  end
end

-- Quoted here rather than through the shared helper: this module is required
-- from toggles.lua, which a couple of suites load on its own without the
-- helpers, and a settings replay that depends on load order would fail the
-- whole config parse.
local function quote(value)
  return "'" .. tostring(value):gsub("'", "'\\''") .. "'"
end

local command = quote(paths.omarchy_path .. "/bin/omarchy-hyprland-setting")
local pipe = io.popen(command .. " list --tsv 2>/dev/null")

if not pipe then
  return
end

local overrides = {}

for line in pipe:lines() do
  local key, kind, value = line:match("^([^\t]+)\t([^\t]+)\t(.*)$")

  if key then
    local converted = typed(kind, value)
    if converted ~= nil then
      assign(overrides, key, converted)
    end
  end
end

pipe:close()

hl.config(overrides)
