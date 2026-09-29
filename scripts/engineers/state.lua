-- Engineers state. Created on first use, so a save without constructors
-- never gets it.
--
-- storage.engineers = {
--   constructors[unit_number] = constructor record (constructor.lua)
--   ghosts[surface_index .. ':' .. force_index] = ghost bucket (ghosts.lua)
--   scanned[surface_index] = true once that surface's ghosts were read
--   claims[ghost unit_number] = constructor unit_number
--   blocked[ghost unit_number] = tick until which no constructor takes it
--   teams[constructor unit_number] = {members, state, present} (teams.lua)
--   team_of[soldier unit_number] = constructor unit_number
--   signatures[force_index] = the pool and constructors the last split saw
--   task_forces[id] = task force record (task_force.lua)
--   next_task_force = the last task force id
--   min_team = test override of constructor.MIN_TEAM
--   dirty = true when the next split must run
-- }
local M = {}

function M.get()
  local s = storage.engineers
  if not s then
    s = {constructors = {}, ghosts = {}, scanned = {}, claims = {}, blocked = {}, teams = {}, team_of = {},
      signatures = {}, task_forces = {}, next_task_force = 0, dirty = true}
    storage.engineers = s
  end
  return s
end

-- The state, or nil without creating it, for hot paths.
function M.peek()
  return storage.engineers
end

return M
