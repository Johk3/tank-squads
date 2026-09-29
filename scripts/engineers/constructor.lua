-- Constructor: an unmanned wall-laying vehicle. It fills the force's wall
-- and gate ghosts that construction robots cannot reach, while its escort
-- team rings it.
--
-- record = {entity, id, force_index, surface_index, state, since, said,
--   cluster, centre, fails, retries, crane, release_tick, done_tick,
--   released, paused_since, calm_since, task_force, task_force_result}
-- state is 'waiting', 'seeking', 'moving', 'building', 'paused',
-- 'task_force', 'healing' or 'idle'.
local names = require('scripts.names')
local state = require('scripts.engineers.state')
local ghosts = require('scripts.engineers.ghosts')

local M = {}

function M.register(entity)
  if not (entity and entity.valid and entity.name == names.constructor) then return nil end
  local s = state.get()
  local record = s.constructors[entity.unit_number]
  if record then return record end
  record = {entity = entity, id = entity.unit_number, force_index = entity.force_index,
    surface_index = entity.surface_index, state = 'seeking', since = game.tick, said = {}}
  s.constructors[record.id] = record
  s.dirty = true
  ghosts.scan(entity.surface)
  return record
end

function M.unregister(unit_number)
  local s = state.peek()
  local record = s and s.constructors[unit_number]
  if not record then return end
  s.constructors[unit_number] = nil
  s.dirty = true
end

-- A finished constructor leaves the barracks door. Returns false when there
-- is no room, so the recruit waits in the machine.
function M.deploy(barracks_entity)
  local surface, p = barracks_entity.surface, barracks_entity.position
  local position = surface.find_non_colliding_position(names.constructor, {x = p.x, y = p.y + 3}, 16, 1)
  if not position then return false end
  local entity = surface.create_entity{name = names.constructor, position = position, force = barracks_entity.force}
  if not entity then return false end
  M.register(entity)
  return true
end

function M.count(force_index)
  local s = state.peek()
  local n = 0
  for _, record in pairs(s and s.constructors or {}) do
    if record.force_index == force_index then n = n + 1 end
  end
  return n
end

return M
