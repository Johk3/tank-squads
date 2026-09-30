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
--   signatures[force_index .. ':' .. surface_index] = the pool and
--     constructors the last split saw
--   task_forces[id] = task force record (task_force.lua)
--   next_task_force = the last task force id
--   min_team = test override of constructor.MIN_TEAM
--   dirty = true when the next split must run
--   rings[force_index] = the force's rings and ring settings (rings/rings.lua)
--   ring_ghosts[ghost unit_number] = {ring = key, segment = i}
--   plan_tick = the tick the last ring segment was planned
--   dismantle[ring key] = walls of a ring being taken down (rings/dismantle.lua)
--   crossings[unit_number] = a unit crossing a ring (rings/crossing.lua)
--   armed[player_index] = {n, tick}: a ring delete waiting for its second click
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
