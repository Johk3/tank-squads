-- The engineers feature: constructors, their escort teams and nest task
-- forces. The rest of the mod calls this module only, except the leaf
-- module loans.lua, which patrol, cover and commands read.
local constructor = require('scripts.engineers.constructor')

local M = {}

M.register = constructor.register
M.deploy = constructor.deploy
M.count = constructor.count

function M.unregister(unit_number)
  constructor.unregister(unit_number)
end

return M
