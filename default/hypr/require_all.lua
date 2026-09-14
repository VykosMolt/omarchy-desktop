-- Require every *.lua file in a directory in sorted order.
-- Used for Omarchy extension-style folders such as default/hypr/apps,
-- default/hypr/bindings, and the active Omarchy state toggles directory.
-- Pass a module prefix for normal package.path modules, e.g.
--   require_all.files(paths.omarchy_path .. "/default/hypr/apps", "default.hypr.apps")
-- Pass nil to execute files directly from the directory on each call.
-- Pass options.exclude as a set of base names (without ".lua") to skip; a legacy
-- file that must never be loaded as code stays on disk for a migration to remove.

local M = {}

local function shell_quote(path)
  return "'" .. path:gsub("'", "'\\''") .. "'"
end

function M.files(dir, module_prefix, options)
  local exclude = options and options.exclude or {}
  local handle = io.popen("find " .. shell_quote(dir) .. " -maxdepth 1 -type f -name '*.lua' -printf '%f\\n' 2>/dev/null | sort")
  if handle then
    for filename in handle:lines() do
      local name = filename:gsub("%.lua$", "")
      if not exclude[name] then
        if module_prefix then
          local module = module_prefix .. "." .. name
          if options and options.reload then
            package.loaded[module] = nil
          end
          require(module)
        else
          dofile(dir .. "/" .. filename)
        end
      end
    end
    handle:close()
  end
end

return M
