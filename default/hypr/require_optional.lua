-- Require a module only when it can be found on package.path.
-- Errors inside existing modules still surface normally.

local M = {}

function M.module(module)
  if package.searchpath(module, package.path) then
    return require(module)
  end
end

function M.file(path)
  local file = io.open(path, "r")
  if file then
    file:close()
    return dofile(path)
  end
end

return M
