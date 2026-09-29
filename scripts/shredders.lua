-- Shredders: unmanned rammers that support divisions on their own.
--
-- storage.shredders = {
--   units[unit_number] = record (see M.register)
--   groups[player_index .. ':' .. n] = the shredders of one operational
--     division: {key, player_index, n, force_index, surface_index, members,
--     point, ordered, home, window, updated}
--   shadows[player_index] = shredders following a player in danger:
--     {members, surface_index, force_index, point, ordered, calm_since, spent}
--   locks[target unit_number] = shredders aimed at it
--   doomed[unit_number] = true for crashed shredders the next slice removes
--   present[force_index .. ':' .. surface_index] = true where shredders are
-- }
-- Everything runs from events and the existing sweep slices; a parked
-- shredder costs nothing until its division moves.
local names = require('scripts.names')

local M = {}

M.PARKED, M.CHARGING = names.shredder, names.shredder_charging
M.EFFECT = 'tank-squad-shredder-impact'

function M.state()
  local s = storage.shredders
  if not s then
    s = {units = {}, groups = {}, shadows = {}, locks = {}, doomed = {}, present = {}}
    storage.shredders = s
  end
  return s
end

local function remove(list, id)
  for i = #list, 1, -1 do
    if list[i] == id then table.remove(list, i); return true end
  end
  return false
end

-- Takes the shredder out of its group or shadow.
local function leave(record)
  local s = M.state()
  if record.group then
    local group = s.groups[record.group]
    if group then remove(group.members, record.id) end
    record.group = nil
  end
  if record.shadow then
    local shadow = s.shadows[record.shadow]
    if shadow then remove(shadow.members, record.id) end
    record.shadow = nil
  end
end

local function unlock(record)
  if record.lock_id then
    local locks = M.state().locks
    local n = (locks[record.lock_id] or 1) - 1
    locks[record.lock_id] = n > 0 and n or nil
  end
  record.target, record.lock_id = nil, nil
end

local function clear_renders(record)
  for key, object in pairs(record.renders) do
    if object.valid then object.destroy() end
    record.renders[key] = nil
  end
end

-- record = {entity, id, state, group, shadow, home_position, homeward,
--   target, target_position, lock_id, renders}. state is 'parked',
-- 'moving', 'igniting', 'charging' or 'spent'.
function M.register(entity)
  if not (entity and entity.valid and names.shredder_set[entity.name]) then return nil end
  local s = M.state()
  local record = s.units[entity.unit_number]
  if record then return record end
  record = {entity = entity, id = entity.unit_number, state = 'moving', renders = {}}
  s.units[record.id] = record
  return record
end

function M.unregister(unit_number)
  local s = storage.shredders
  local record = s and s.units[unit_number]
  if not record then return end
  leave(record)
  unlock(record)
  clear_renders(record)
  s.units[unit_number] = nil
  s.doomed[unit_number] = nil
end

-- A finished shredder leaves the barracks door. Returns false when there is
-- no room, so the recruit waits in the machine like a soldier's.
function M.deploy(barracks_entity, rally)
  local surface, p = barracks_entity.surface, barracks_entity.position
  local position = surface.find_non_colliding_position(M.PARKED, {x = p.x, y = p.y + 2.5}, 16, 1)
  if not position then return false end
  local entity = surface.create_entity{name = M.PARKED, position = position, force = barracks_entity.force}
  if not entity then return false end
  local record = M.register(entity)
  record.home_position = rally and {x = rally.x, y = rally.y} or {x = p.x, y = p.y}
  return true
end

function M.tick(phase) end

function M.on_soldier_died(entity) return 0 end

function M.on_damaged(event)
  local entity = event.entity
  return entity ~= nil and entity.valid == true and names.shredder_set[entity.name] == true
end

function M.on_command_completed(unit_number, result)
  local s = storage.shredders
  return s ~= nil and s.units[unit_number] ~= nil
end

function M.on_trigger(event)
  return event.effect_id == M.EFFECT
end

function M.release(player_index) end

function M.strike(ids, surface, position, force, radius) return 0 end

return M
