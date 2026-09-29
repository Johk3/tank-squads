-- The engineers feature: constructors, their escort teams and nest task
-- forces. The rest of the mod calls this module only, except the leaf
-- module loans.lua, which patrol, cover and commands read.
local constructor = require('scripts.engineers.constructor')
local ghosts = require('scripts.engineers.ghosts')

local M = {}

M.register = constructor.register
M.deploy = constructor.deploy
M.count = constructor.count
M.on_ghost = ghosts.add

-- A wall or gate that died left a ghost when the force keeps ghosts of
-- destroyed buildings.
function M.on_post_died(event)
  local ghost = event.ghost
  if ghost and ghost.valid then ghosts.add(ghost) end
end

function M.unregister(unit_number)
  constructor.unregister(unit_number)
end

return M
