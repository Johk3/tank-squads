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
local divisions = require('scripts.divisions')
local geometry = require('scripts.shredder_geometry')

local M = {}

M.PARKED, M.CHARGING = names.shredder, names.shredder_charging
M.EFFECT = 'tank-squad-shredder-impact'
M.REBALANCE_PHASE = 5
M.DRIFT = 20
-- A group its division slice has not refreshed for this long lost its slot.
M.STALE = 120
local READY = {parked = true, moving = true}

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

local function send(record, position)
  record.state = 'moving'
  record.entity.commandable.set_command{type = defines.command.go_to_location, destination = position,
    radius = 2, distraction = defines.distraction.none}
end

local function park(record)
  record.state = 'parked'
  record.entity.commandable.set_command{type = defines.command.stop, distraction = defines.distraction.none}
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


function M.on_soldier_died(entity) return 0 end

function M.on_damaged(event)
  local entity = event.entity
  return entity ~= nil and entity.valid == true and names.shredder_set[entity.name] == true
end


function M.on_trigger(event)
  return event.effect_id == M.EFFECT
end

function M.release(player_index) end

function M.strike(ids, surface, position, force, radius) return 0 end

-- Nearest own barracks or headquarters on the surface, or nil.
function M.home(surface_index, force_index, position)
  local best, best_d
  local function consider(entity)
    if entity and entity.valid and entity.surface_index == surface_index and entity.force_index == force_index then
      local d = geometry.distance2(entity.position, position)
      if not best_d or d < best_d then best, best_d = entity, d end
    end
  end
  for _, b in ipairs(storage.barracks or {}) do consider(b.entity) end
  for _, r in pairs(storage.headquarters or {}) do consider(r.entity) end
  return best
end

-- Sends the group's ready shredders to their slots around its backline.
function M.post(group)
  group.ordered = group.point
  local units = M.state().units
  for i, id in ipairs(group.members) do
    local record = units[id]
    if record and READY[record.state] then send(record, geometry.slot(group.point, i)) end
  end
end

function M.drop_group(key)
  local s = M.state()
  local group = s.groups[key]
  if not group then return end
  for _, id in ipairs(group.members) do
    local record = s.units[id]
    if record then record.group = nil end
  end
  s.groups[key] = nil
end

-- Runs in the division's own slice, right after the roster refresh, so it
-- reuses the cached members. A division counts when it has an armed
-- soldier; its surface is that soldier's.
function M.update_group(player_index, n)
  local s = M.state()
  local key = player_index .. ':' .. n
  local player = game.get_player(player_index)
  local members = player and divisions.cached(player_index, n) or {}
  local surface_index
  for _, e in ipairs(members) do
    if names.soldier_set[e.name] then surface_index = e.surface_index; break end
  end
  if not surface_index then M.drop_group(key); return end
  local here = {}
  for _, e in ipairs(members) do if e.surface_index == surface_index then here[#here + 1] = e end end
  local centre = geometry.centre(here)
  local group = s.groups[key]
  if not group then
    group = {key = key, player_index = player_index, n = n, members = {}}
    s.groups[key] = group
  end
  group.force_index, group.surface_index, group.updated = player.force.index, surface_index, game.tick
  local home = group.home
  if not (home and home.valid and home.surface_index == surface_index) then
    home = M.home(surface_index, group.force_index, centre)
    group.home = home
  end
  local enemy
  if not home then
    enemy = here[1].surface.find_nearest_enemy{position = centre, max_distance = 100, force = player.force}
  end
  group.point = geometry.backline(centre, home and home.position, enemy and enemy.position)
  if not group.ordered or geometry.distance2(group.ordered, group.point) > M.DRIFT * M.DRIFT then
    M.post(group)
  end
end

-- Pooled shredders with no division to serve wait at their rally point.
local function go_home(record)
  if record.homeward or not record.home_position then return end
  send(record, record.home_position)
  record.homeward = true
end

-- The even split, per force and surface. Reads only group records the
-- division slices keep current, so it walks no roster.
function M.rebalance()
  local s = M.state()
  local tick = game.tick
  local keys = {}
  for key, group in pairs(s.groups) do
    if tick - (group.updated or 0) > M.STALE then keys[#keys + 1] = key end
  end
  for _, key in ipairs(keys) do M.drop_group(key) end
  local buckets, present = {}, {}
  local function bucket(force_index, surface_index)
    local k = force_index .. ':' .. surface_index
    local b = buckets[k]
    if not b then b = {groups = {}, pool = {}, by_key = {}}; buckets[k] = b end
    return b
  end
  keys = {}
  for key in pairs(s.groups) do keys[#keys + 1] = key end
  table.sort(keys)
  for _, key in ipairs(keys) do
    local group = s.groups[key]
    local entry = {key = key, point = group.point, members = {}}
    local b = bucket(group.force_index, group.surface_index)
    b.groups[#b.groups + 1] = entry
    b.by_key[key] = entry
  end
  local ids = {}
  for id in pairs(s.units) do ids[#ids + 1] = id end
  table.sort(ids)
  for _, id in ipairs(ids) do
    local record = s.units[id]
    local e = record.entity
    if not e.valid then
      M.unregister(id)
    else
      present[e.force_index .. ':' .. e.surface_index] = true
      if READY[record.state] and not record.shadow then
        local b = bucket(e.force_index, e.surface_index)
        local item = {id = id, position = e.position}
        local entry = record.group and b.by_key[record.group]
        if entry then
          entry.members[#entry.members + 1] = item
        else
          if record.group then leave(record) end
          b.pool[#b.pool + 1] = item
        end
      end
    end
  end
  s.present = present
  for _, b in pairs(buckets) do
    if #b.groups == 0 then
      for _, item in ipairs(b.pool) do go_home(s.units[item.id]) end
    else
      local changes = geometry.rebalance(b.groups, b.pool)
      local moved = {}
      for id in pairs(changes) do moved[#moved + 1] = id end
      table.sort(moved)
      for _, id in ipairs(moved) do
        local record, key = s.units[id], changes[id]
        leave(record)
        record.homeward = nil
        if key then
          local group = s.groups[key]
          group.members[#group.members + 1] = id
          record.group = key
          send(record, geometry.slot(group.point, #group.members))
        end
      end
    end
  end
end

-- Crashed shredders leave in the next slice; see M.on_trigger.
function M.reap() end

-- Shadows follow players in danger; see M.watch_player.
function M.watch(phase) end

function M.tick(phase)
  local s = storage.shredders
  if not (s and next(s.units)) then return end
  M.reap()
  for player_index, pstate in pairs(storage.divisions or {}) do
    for n in pairs(pstate.slots) do
      if n ~= 0 and divisions.in_phase(player_index, n, phase) then M.update_group(player_index, n) end
    end
  end
  if phase == nil or phase == M.REBALANCE_PHASE then M.rebalance() end
  M.watch(phase)
end

function M.on_command_completed(unit_number, result)
  local s = storage.shredders
  local record = s and s.units[unit_number]
  if not record then return false end
  if record.state == 'moving' then park(record) end
  return true
end

return M
